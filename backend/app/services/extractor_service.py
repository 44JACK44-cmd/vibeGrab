import subprocess
import json
import queue
import re
import threading
import time
import html as htmllib
from urllib.parse import urlparse, parse_qs, unquote
from app.core.config import settings
from app.core.logging import logger
from app.schemas.analyze import MediaInfo, FormatOption

_KWAI_HOST_SUFFIXES = ("kwai.com", "kuaishou.com")
_KWAI_HOST_SUBSTRINGS = ("kwai", "kuaishou")
_KWAI_MOBILE_UA = (
    "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
)
_ISO_DURATION = re.compile(r"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$")


class ExtractionError(Exception):
    """Raised when a media page cannot be parsed or downloaded."""


def is_kwai_url(url: str) -> bool:
    try:
        host = (urlparse(url).hostname or "").lower()
    except Exception:
        return False
    if not host:
        return False
    if host.endswith(_KWAI_HOST_SUFFIXES):
        return True
    return any(token in host for token in _KWAI_HOST_SUBSTRINGS)


def _iso_to_seconds(value: str | None) -> int | None:
    if not value:
        return None
    m = _ISO_DURATION.match(value)
    if not m:
        return None
    hours, minutes, seconds = (int(g) if g else 0 for g in m.groups())
    total = hours * 3600 + minutes * 60 + seconds
    return total or None


def _og_content(page_html: str, name: str) -> str | None:
    """Return the content of an OpenGraph <meta> tag, if present."""
    m = re.search(
        r'<meta[^>]*property="%s"[^>]*content="([^"]*)"' % re.escape(name),
        page_html,
    )
    return htmllib.unescape(m.group(1).strip()) if m else None


def _pick_kwai_video_url(mp4s: list[str], thumbnail: str) -> str:
    """Prefer the mp4 whose id matches the og:image thumbnail."""
    if not thumbnail:
        return mp4s[0]
    image_id = thumbnail.rsplit("/", 1)[-1].split("_")[0]
    if not image_id:
        return mp4s[0]
    for candidate in mp4s:
        if image_id in candidate:
            return candidate
    return mp4s[0]


def _kwai_uploader(page_html: str, url: str) -> str | None:
    author_m = re.search(r'"author":"([^"]+)"', page_html)
    if author_m:
        return author_m.group(1)
    username_m = re.search(r"/@([^/?#]+)", url)
    return username_m.group(1) if username_m else None


def _kwai_height(page_html: str) -> int | None:
    dims_m = re.search(r'"width":(\d+),"height":(\d+)', page_html)
    return int(dims_m.group(2)) if dims_m else None


def _kwai_video_id(url: str) -> str:
    id_m = re.search(r"/(?:video|photo)/(\d+)", url)
    return id_m.group(1) if id_m else str(abs(hash(url)) % 10**12)


def parse_kwai_page(page_html: str, url: str) -> dict:
    """Pull video metadata out of a Kwai SSR page. Raises if nothing found."""
    mp4s = re.findall(r'https://[^"\'\s]+?\.mp4[^"\'\s]*', page_html)
    if not mp4s:
        raise ExtractionError("No video URL found in Kwai page")

    thumbnail = _og_content(page_html, "og:image") or ""
    video_url = _pick_kwai_video_url(mp4s, thumbnail)

    caption = _og_content(page_html, "og:description") or ""
    uploader = _kwai_uploader(page_html, url)
    title = caption.strip() or (f"@{uploader} on Kwai" if uploader else "Kwai video")

    dur_m = re.search(r'"duration":"(PT[^"]+)"', page_html)
    duration = _iso_to_seconds(dur_m.group(1) if dur_m else None)

    return {
        "id": _kwai_video_id(url),
        "title": title,
        "thumbnail": thumbnail or None,
        "duration": duration,
        "uploader": uploader,
        "height": _kwai_height(page_html),
        "url": video_url,
    }


_KWAI_IN_TEXT = re.compile(
    r'https?://(?:[\w-]+\.)*(?:kwai|kuaishou)\.com[^"\'\s<>\\]*'
)


def _find_kwai_url(text: str) -> str | None:
    """Return the first valid Kwai link embedded in text, if any."""
    for m in _KWAI_IN_TEXT.finditer(text):
        candidate = m.group(0).rstrip("\\,;")
        if is_kwai_url(candidate):
            return candidate
    return None


def _kwai_from_query(final_url: str) -> str | None:
    """Search the redirect page query string for an embedded Kwai link."""
    try:
        query = parse_qs(urlparse(final_url).query)
    except Exception:  # noqa: BLE001 - malformed urls fall through to page scan
        return None
    for key in ("af_sub1", "target_url", "deep_link_value", "af_dp"):
        for value in query.get(key, []):
            found = _find_kwai_url(unquote(value))
            if found:
                return found
    return None


def _resolve_kwai_target(final_url: str, page_text: str) -> str | None:
    """Recover the real Kwai page URL from short-link redirect pages.

    Short links (kwai-video.com/p/...) bounce through an AppsFlyer
    onelink page that embeds the target URL either percent-encoded in
    the query string or raw inside its JS.
    """
    found = _kwai_from_query(final_url)
    if found:
        return found

    for text in (page_text, unquote(page_text)):
        found = _find_kwai_url(text)
        if found:
            return found
    return None


def extract_kwai(url: str, _hop: int = 0) -> tuple[MediaInfo, list[FormatOption]]:
    from curl_cffi import requests as cffi_requests

    logger.info(f"Running Kwai extractor for: {url}")
    response = cffi_requests.get(
        url,
        impersonate="chrome",
        headers={"User-Agent": _KWAI_MOBILE_UA},
        timeout=30,
        allow_redirects=True,
    )
    if response.status_code >= 400:
        raise ExtractionError(f"Kwai page returned HTTP {response.status_code}")

    final_url = str(getattr(response, "url", None) or url)

    try:
        meta = parse_kwai_page(response.text, final_url)
    except Exception:
        target = _resolve_kwai_target(final_url, response.text)
        if target and _hop < 3 and target.rstrip("/") != url.rstrip("/"):
            logger.info(f"Kwai short link resolved to: {target}")
            return extract_kwai(target, _hop=_hop + 1)
        raise

    size_bytes = None
    try:
        head = cffi_requests.head(
            meta["url"],
            impersonate="chrome",
            timeout=10,
            allow_redirects=True,
        )
        size_bytes = int(head.headers.get("content-length") or 0) or None
    except Exception:
        size_bytes = None

    media = MediaInfo(
        id=meta["id"],
        title=meta["title"],
        thumbnail=meta["thumbnail"],
        duration=meta["duration"],
        uploader=meta["uploader"],
        source="kwai",
        platform="kwai",
    )
    fmt = FormatOption(
        id="direct-mp4",
        type="video",
        extension="mp4",
        quality=f"{meta['height']}p" if meta["height"] else "hd",
        has_video=True,
        has_audio=True,
        size_bytes=size_bytes,
        direct_url=meta["url"],
    )
    return media, [fmt]


# --- YouTube extraction -------------------------------------------------
#
# One yt-dlp run per player client, all of them at once:
#
#   * the tv/web clients answer with the full ladder (audio-only tracks plus
#     video up to 4K) which is what the download sheet needs to offer real
#     choices;
#   * the android client answers with a single 360p muxed stream, so it is
#     kept for the case the web player rejects the datacenter IP of the
#     server, never as the first choice.
#
# Running them in parallel means the extra clients cost no extra wall time:
# the first rich answer wins and the rest are stopped.
_YT_CLIENTS = ("tv_embedded", "default", "android")
_YT_HOSTS = ("youtube.com", "youtu.be", "youtube-nocookie.com")
_CLIENT_TIMEOUT = 30
_OVERALL_TIMEOUT = 40

# Extractions are reused for a short while: a retry, a double tap or sharing
# the same link twice used to spawn another yt-dlp process each time. The
# signed media URLs stay valid for hours, so a few minutes of cache is safe.
_CACHE_TTL = 300.0
_cache: dict[str, tuple[float, dict]] = {}
_cache_lock = threading.Lock()


def _cache_get(url: str) -> dict | None:
    with _cache_lock:
        hit = _cache.get(url)
    if not hit:
        return None
    expires_at, data = hit
    if time.monotonic() >= expires_at:
        with _cache_lock:
            _cache.pop(url, None)
        return None
    return data


def _cache_put(url: str, data: dict) -> None:
    with _cache_lock:
        if len(_cache) > 128:
            _cache.clear()
        _cache[url] = (time.monotonic() + _CACHE_TTL, data)


def _is_youtube(url: str) -> bool:
    try:
        host = (urlparse(url).hostname or "").lower()
    except Exception:
        return False
    return any(host == h or host.endswith("." + h) for h in _YT_HOSTS)


def _spawn_extract(url: str, client: str | None) -> subprocess.Popen:
    cmd = [
        settings.YT_DLP_PATH,
        "--dump-json",
        "--no-download",
        "--no-warnings",
        "--no-playlist",
    ]
    if client:
        cmd += ["--extractor-args", f"youtube:player_client={client}"]
    cmd.append(url)
    return subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )


def _richness(data: dict) -> tuple[int, int, int]:
    """(audio-only tracks, video heights, usable formats) of one answer."""
    usable = [
        f
        for f in data.get("formats") or []
        if str(f.get("url") or "").startswith("http")
        and "mhtml" not in str(f.get("ext") or "")
    ]
    audio_only = sum(
        1
        for f in usable
        if f.get("acodec", "none") != "none" and f.get("vcodec", "none") == "none"
    )
    heights = {f.get("height") for f in usable if f.get("height")}
    return (1 if audio_only else 0, len(heights), len(usable))


def _read_result(client: str, proc: subprocess.Popen, out: queue.Queue) -> None:
    """Read one client's output and report it back to the coordinator."""
    try:
        stdout, stderr = proc.communicate(timeout=_CLIENT_TIMEOUT)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        out.put((client, None, "yt-dlp timed out"))
        return

    if proc.returncode == 0 and stdout.strip():
        try:
            out.put((client, json.loads(stdout), None))
            return
        except json.JSONDecodeError:
            out.put((client, None, "invalid json from yt-dlp"))
            return
    out.put((client, None, (stderr or "").strip()[:500] or "yt-dlp failed"))


def _extract_youtube(url: str) -> dict:
    """Ask every player client at once and keep the richest answer."""
    logger.info(f"Running extractor for: {url} (clients={'+'.join(_YT_CLIENTS)})")
    results: "queue.Queue[tuple[str, dict | None, str | None]]" = queue.Queue()
    procs = {
        client: _spawn_extract(url, None if client == "default" else client)
        for client in _YT_CLIENTS
    }
    remaining = len(procs)
    for client, proc in procs.items():
        threading.Thread(
            target=_read_result, args=(client, proc, results), daemon=True
        ).start()

    best: dict | None = None
    errors: list[str] = []
    deadline = time.monotonic() + _OVERALL_TIMEOUT

    while remaining > 0 and time.monotonic() < deadline:
        try:
            client, data, error = results.get(timeout=1.0)
        except queue.Empty:
            continue
        remaining -= 1
        if data is None:
            errors.append(f"{client}: {error}")
            continue
        if best is None or _richness(data) > _richness(best):
            best = data
        audio_only, heights, _ = _richness(data)
        if audio_only and heights >= 3:
            # Good enough for the whole download sheet: stop the rest.
            break

    for proc in procs.values():
        if proc.poll() is None:
            proc.kill()
            proc.wait()

    if best is not None:
        return best
    raise ExtractionError("yt-dlp error: " + ("; ".join(errors) or "no answer"))


def _extract_single(url: str) -> dict:
    """One yt-dlp run for providers that take no player client."""
    logger.info(f"Running extractor for: {url} (client=default)")
    proc = _spawn_extract(url, None)
    try:
        stdout, stderr = proc.communicate(timeout=_CLIENT_TIMEOUT + 15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.communicate()
        raise ExtractionError("yt-dlp timed out") from None

    if proc.returncode == 0 and stdout.strip():
        try:
            return json.loads(stdout)
        except json.JSONDecodeError:
            raise ExtractionError("invalid json from yt-dlp") from None
    raise ExtractionError(f"yt-dlp error: {(stderr or '').strip()[:500]}")


def extract_info(url: str) -> dict:
    """Extract one media URL, reusing a very recent answer for the same link."""
    cached = _cache_get(url)
    if cached is not None:
        logger.info(f"Extractor cache hit for: {url}")
        return cached

    data = _extract_youtube(url) if _is_youtube(url) else _extract_single(url)

    _cache_put(url, data)
    return data


def _best_thumbnail(data: dict) -> str | None:
    thumbnails = data.get("thumbnails", [])
    if thumbnails:
        for t in thumbnails:
            if (t.get("height") or 0) >= 360:
                return t.get("url")
        return thumbnails[-1].get("url")
    return data.get("thumbnail")


def _format_option(
    fmt: dict, fmt_type: str, quality: str, has_video: bool, has_audio: bool
) -> FormatOption:
    """Build a FormatOption from a raw yt-dlp format entry."""
    return FormatOption(
        id=fmt.get("format_id", ""),
        type=fmt_type,
        extension=fmt.get("ext", "mp4"),
        quality=quality,
        has_video=has_video,
        has_audio=has_audio,
        size_bytes=fmt.get("filesize") or fmt.get("filesize_approx"),
        direct_url=fmt.get("url") or "",
    )


def _normalize_format(fmt: dict) -> FormatOption | None:
    height = fmt.get("height")
    vcodec = fmt.get("vcodec", "none")
    acodec = fmt.get("acodec", "none")

    has_video = vcodec != "none" and height is not None
    has_audio = acodec != "none"

    if not has_video and not has_audio:
        return None

    url = fmt.get("url") or ""
    protocol = str(fmt.get("protocol") or "")
    if not url.startswith(("http://", "https://")):
        return None
    if "m3u8" in protocol or "m3u8" in url or "dash" in protocol:
        return None

    if has_video:
        return _format_option(fmt, "video", f"{height}p", True, has_audio)

    abr = fmt.get("abr")
    quality = f"{int(abr)}kbps" if abr else "audio"
    return _format_option(fmt, "audio", quality, False, True)


def _audio_sort_key(quality: str) -> int:
    if quality.endswith("kbps"):
        try:
            return int(quality[:-4])
        except ValueError:
            return 0
    return 0


def _collect_formats(
    raw_formats: list[dict],
) -> tuple[dict[str, FormatOption], dict[int, FormatOption], dict[int, FormatOption]]:
    """Group usable formats into audio, combined (muxed) and video-only maps."""
    audio_by_quality: dict[str, FormatOption] = {}
    video_combined: dict[int, FormatOption] = {}
    video_only: dict[int, FormatOption] = {}

    for fmt in raw_formats:
        normalized = _normalize_format(fmt)
        if normalized is None:
            continue

        height = fmt.get("height")

        if normalized.type == "audio":
            abr = fmt.get("abr") or 0
            key = normalized.quality or ""
            if key not in audio_by_quality or abr > 0:
                audio_by_quality[key] = normalized

        elif normalized.has_audio and height:
            size = fmt.get("filesize") or fmt.get("filesize_approx") or 0
            if height not in video_combined or size > 0:
                video_combined[height] = normalized

        elif height:
            video_only.setdefault(height, normalized)

    return audio_by_quality, video_combined, video_only


def _pick_best_formats(raw_formats: list[dict]) -> list[FormatOption]:
    audio_by_quality, video_combined, video_only = _collect_formats(raw_formats)

    formats: list[FormatOption] = []
    for q in sorted(audio_by_quality, key=_audio_sort_key, reverse=True):
        formats.append(audio_by_quality[q])
    for h in sorted(video_combined, reverse=True):
        formats.append(video_combined[h])
    for h in sorted(video_only, reverse=True):
        formats.append(video_only[h])
    return formats


def extract_media_info(url: str) -> tuple[MediaInfo, list[FormatOption]]:
    from app.services.validation_service import get_source

    if is_kwai_url(url):
        return extract_kwai(url)

    data = extract_info(url)

    media_id = data.get("id", "unknown")
    title = data.get("title", "Untitled")
    thumbnail = _best_thumbnail(data)
    duration = data.get("duration")
    if duration is not None:
        try:
            duration = int(duration)
        except (TypeError, ValueError):
            duration = None
    uploader = data.get("uploader") or data.get("channel")
    source = get_source(url)
    if source == "unknown":
        source = str(data.get("extractor") or "unknown").lower()

    media = MediaInfo(
        id=media_id,
        title=title,
        thumbnail=thumbnail,
        duration=duration,
        uploader=uploader,
        source=source,
        platform=source,
    )

    raw_formats = data.get("formats", [])
    formats = _pick_best_formats(raw_formats)

    if not formats:
        raise ExtractionError("No downloadable formats found")

    return media, formats
