"""Client for sites protected by the Anubis proof-of-work challenge.

The byte-serving paths of our Invidious instance sit behind Anubis
("Making sure you're not a bot"). The algorithm (v1.27, method "fast"):

  1. GET the protected URL -> HTML with <script id="anubis_challenge"> JSON.
  2. Find nonce where sha256(randomData + str(nonce)) hex starts with
     `difficulty` zero characters.
  3. GET /.within.website/x/cmd/anubis/api/pass-challenge?id=...&response=...
     &nonce=...&redir=<url>&elapsedTime=<ms> -> Set-Cookie + redirect.
  4. Re-request the URL with that cookie.

Cookie is bound to client IP + User-Agent, so every request must use the
same UA (ANTUBIS_UA) and come from the same host (our server).
"""

import hashlib
import io
import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.response

from app.core.config import settings
from app.core.logging import logger

ANTUBIS_UA = (
    "Mozilla/5.0 (Linux; Android 14; Pixel 7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Mobile Safari/537.36"
)

# Opening <script id="anubis_challenge"> tag; its JSON body is delimited by
# the following </script> (located with str.find, avoiding a backtracking
# regex with a DOTALL lazy quantifier).
_CHALLENGE_TAG_RE = re.compile(r'<script[^>]*id="anubis_challenge"[^>]*>')

_lock = threading.Lock()
_cookies: dict[str, str] = {}
_cookie_origin: str | None = None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_opener = urllib.request.build_opener(_NoRedirect)


def _is_allowed_url(url: str) -> bool:
    """SSRF guard: only http(s) URLs whose host is on the relay allowlist."""
    parts = urllib.parse.urlsplit(url)
    if parts.scheme not in ("http", "https"):
        return False
    host = (parts.hostname or "").lower()
    if not host:
        return False
    return any(
        host == suffix or host.endswith("." + suffix)
        for suffix in settings.relay_allowed_hosts_list
    )


def _split_cookie(item: str) -> tuple[str, str] | None:
    """Split a Set-Cookie header into (name, value), or None if malformed."""
    first = item.split(";", 1)[0].strip()
    if "=" not in first:
        return None
    name, value = first.split("=", 1)
    return name.strip(), value.strip()


def _apply_cookies(raw: list[str]) -> bool:
    """Merge Set-Cookie values into the shared jar; return True if it changed."""
    global _cookies
    changed = False
    for item in raw:
        parsed = _split_cookie(item)
        if parsed is None:
            continue
        name, value = parsed
        if not value or "Max-Age=0" in item:
            if name in _cookies:
                del _cookies[name]
                changed = True
        else:
            _cookies[name] = value
            changed = True
    return changed


def _store_cookies(header, origin: str) -> None:
    """Apply every Set-Cookie of a response (empty value / Max-Age=0 deletes)."""
    global _cookie_origin
    if header is None:
        return
    raw = header.get_all("Set-Cookie") if hasattr(header, "get_all") else None
    if not raw:
        single = header.get("Set-Cookie")
        raw = [single] if single else []
    changed = _apply_cookies(raw)
    if changed and raw:
        _cookie_origin = origin


def _cookie_header_value() -> str | None:
    if not _cookies:
        return None
    return "; ".join(f"{k}={v}" for k, v in _cookies.items())


def _headers(extra: dict | None = None) -> dict:
    h = {"User-Agent": ANTUBIS_UA}
    ck = _cookie_header_value()
    if ck:
        h["Cookie"] = ck
    if extra:
        h.update(extra)
    return h


def _challenge_payload(challenge_html: bytes) -> dict:
    """Extract and parse the JSON body of the anubis challenge script tag."""
    text = challenge_html.decode(errors="replace")
    m = _CHALLENGE_TAG_RE.search(text)
    if not m:
        raise RuntimeError("anubis challenge not found in page")
    end = text.find("</script>", m.end())
    if end == -1:
        raise RuntimeError("anubis challenge not found in page")
    return json.loads(text[m.end():end])


def _solve_pow(data: str, difficulty: int) -> tuple[int, str]:
    """Find a nonce whose sha256(data+nonce) starts with `difficulty` zeros."""
    target = "0" * difficulty
    nonce = 0
    while True:
        digest_hex = hashlib.sha256(f"{data}{nonce}".encode()).hexdigest()
        if digest_hex.startswith(target):
            return nonce, digest_hex
        nonce += 1
        if nonce > 50_000_000:
            raise RuntimeError("anubis pow did not converge")


def _solve(challenge_html: bytes, original_url: str) -> None:
    payload = _challenge_payload(challenge_html)
    rules = payload.get("rules") or {}
    ch = payload.get("challenge") or {}
    difficulty = int(ch.get("difficulty") or rules.get("difficulty") or 4)
    data = ch.get("randomData") or ""
    ch_id = ch.get("id") or ""

    started = time.time()
    nonce, digest_hex = _solve_pow(data, difficulty)
    elapsed_ms = max(1, int((time.time() - started) * 1000))

    base = urllib.parse.urlsplit(original_url)
    origin = f"{base.scheme}://{base.netloc}"
    query = urllib.parse.urlencode(
        {
            "id": ch_id,
            "response": digest_hex,
            "nonce": nonce,
            "redir": original_url,
            "elapsedTime": str(elapsed_ms),
        }
    )
    pass_url = f"{origin}/.within.website/x/cmd/anubis/api/pass-challenge?{query}"
    logger.info(
        f"Anubis solving: difficulty={difficulty} nonce={nonce} "
        f"elapsed={elapsed_ms}ms"
    )
    # SSRF guard: never solve against a host outside the relay allowlist.
    if not _is_allowed_url(pass_url):
        raise RuntimeError("anubis pass-challenge host not allowed")
    try:
        resp = _opener.open(
            urllib.request.Request(pass_url, headers=_headers()),
            timeout=30,
        )
        _store_cookies(resp.headers, origin)
        resp.close()
    except urllib.error.HTTPError as e:
        if 300 <= e.code < 400:
            _store_cookies(e.headers, origin)
            e.close()
        else:
            body = e.read()[:300]
            e.close()
            raise RuntimeError(f"pass-challenge failed: HTTP {e.code} {body}") from e
    if not _cookies:
        raise RuntimeError("pass-challenge set no cookie")


def _handle_stream_error(e: urllib.error.HTTPError, url: str) -> bool:
    """Handle a streaming HTTP error. Return True when the caller should retry."""
    global _cookies, _cookie_origin
    if 300 <= e.code < 400:
        _store_cookies(e.headers, _origin(url))
        e.close()
        return True
    if e.code in (403, 429, 401) and _cookies:
        # stale cookie: drop and retry
        logger.info(f"Anubis cookie rejected (HTTP {e.code})")
        _cookies = {}
        _cookie_origin = None
        e.close()
        return True
    return False


def open_stream(url: str, extra_headers: dict | None = None, timeout: int = 30):
    """Open a (possibly challenge-protected) URL and return a streaming
    response. Solves Anubis transparently. Caller must close()."""
    if not _is_allowed_url(url):
        raise ValueError("Anubis stream host not allowed")
    with _lock:
        last_err: Exception | None = None
        for _ in range(3):
            try:
                resp = _opener.open(
                    urllib.request.Request(url, headers=_headers(extra_headers)),
                    timeout=timeout,
                )
            except urllib.error.HTTPError as e:
                if not _handle_stream_error(e, url):
                    raise
                last_err = None
                continue

            ctype = (resp.headers.get("Content-Type") or "").lower()
            if "text/html" not in ctype:
                return resp

            _store_cookies(resp.headers, _origin(url))
            body = resp.read()
            resp.close()
            if b"anubis_challenge" in body:
                _solve(body, url)
                last_err = None
                continue
            # plain html (error page): return as-is via in-memory stream
            return urllib.response.addinfourl(
                io.BytesIO(body), resp.headers, url, 200
            )
        raise last_err or RuntimeError("anubis: could not get a clean response")


def _origin(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    return f"{parts.scheme}://{parts.netloc}"


def cookie_header(url: str) -> str | None:
    """Ensure a valid cookie for url (solving the challenge if needed) and
    return it as a 'name=value' header string for e.g. ffmpeg."""
    with _lock:
        if any("anubis-auth" in k for k in _cookies):
            # auth cookie already solved in this process: skip the round trip
            return _cookie_header_value()
    resp = open_stream(url)
    try:
        resp.read(1024)
    finally:
        resp.close()
    with _lock:
        return _cookie_header_value()
