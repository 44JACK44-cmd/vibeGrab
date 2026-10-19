import json
import re
import threading
import time
import urllib.parse
import urllib.request
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor

from app.core.logging import logger
from app.services import relay_warm

_UA_COOKIES = {
    "Cookie": "CONSENT=YES+cb.20210328-17-p0.en+FX+000; SOCS=CAI",
    "Accept-Language": "en-US,en;q=0.9",
}
# Public InnerTube API key: this is the same well-known key that yt-dlp and
# other web clients embed in their own bundles. It is not a secret and grants
# no account access; it only identifies the anonymous WEB client.
_INNERTUBE_API_KEY = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"  # NOSONAR
# Static innertube config. clientVersion must match yt-dlp's real WEB value
# and (like yt-dlp) we omit ?key= and never send an empty X-Goog-Visitor-Id.
# Even so, YouTube answers 403 ("Sorry..." bot page) to /next from datacenter
# IPs (Render), so get_related/get_comments fall back to a Invidious instance
# (which fetches YouTube from its own IP) and then to yt-dlp.
_STATIC_CONFIG = {
    "api_key": _INNERTUBE_API_KEY,
    "visitor": "",
    "context": {
        "client": {
            "clientName": "WEB",
            "clientVersion": "2.20260708.00.00",
            "hl": "en",
            "gl": "US",
        }
    },
}

_BROWSER_UA = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36"
)
# Invidious instances used when the direct innertube call is blocked.
_INVIDIOUS_BASES = ["https://invidious.f5.si"]
# After an innertube 403/429, skip it for this long (avoid a ~10s penalty
# on every request while YouTube is blocking our datacenter IP).
_NEXT_FAIL_UNTIL = 0.0
_NEXT_FAIL_TTL = 120.0

_YT_INITIAL_RE = re.compile(r"var ytInitialData = ([^}]+)\};</script>", re.S)
_API_KEY_RE = re.compile(r'"INNERTUBE_API_KEY":"([^"]+)"')
_VISITOR_RE = re.compile(r'"VISITOR_DATA":"([^"]+)"')
_DURATION_RE = re.compile(r"\d+(?::\d+)+$")
_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
_COMMENT_PANEL_HINT = "comment"
_AUDIO_MIME_PREFIX = "audio/"
# Invidious fallback paths are built from whitelisted, single-level segments
# only: no scheme/host, no traversal and no URL metacharacters.
_INVIDIOUS_SEGMENT_RE = re.compile(r"^[A-Za-z0-9._~-]+$")
_INVIDIOUS_QUERY_RE = re.compile(r"^[A-Za-z0-9._~=&%-]+$")

_TTL_WATCH = 600
_TTL_RELATED = 900
_TTL_COMMENTS = 600

_cache: dict[str, tuple[float, object]] = {}
_cache_lock = threading.Lock()


class WatchError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


def _cache_get(key: str):
    with _cache_lock:
        hit = _cache.get(key)
        if hit and hit[0] > time.time():
            return hit[1]
    return None


def _cache_put(key: str, value, ttl: float) -> None:
    with _cache_lock:
        _cache[key] = (time.time() + ttl, value)


def clear_cache() -> None:
    with _cache_lock:
        _cache.clear()


def _extract_json_after(text: str, marker: str) -> dict:
    i = text.index(marker)
    i = text.index("{", i)
    depth = 0
    in_str = False
    esc = False
    for j in range(i, len(text)):
        c = text[j]
        if in_str:
            if esc:
                esc = False
            elif c == "\\":
                esc = True
            elif c == '"':
                in_str = False
            continue
        if c == '"':
            in_str = True
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return json.loads(text[i:j + 1])
    raise ValueError("unbalanced json after marker")


def extract_innertube(html: str) -> dict:
    key_m = _API_KEY_RE.search(html)
    if not key_m:
        raise WatchError(502, "YouTube config missing (api key)")
    visitor_m = _VISITOR_RE.search(html)
    try:
        context = _extract_json_after(html, '"INNERTUBE_CONTEXT"')
    except Exception:
        context = {
            "client": {
                "clientName": "WEB",
                "clientVersion": "2.20261001.00.00",
                "hl": "en",
                "gl": "US",
            }
        }
    return {
        "api_key": key_m.group(1),
        "visitor": visitor_m.group(1) if visitor_m else "",
        "context": context,
    }


def _runs_text(node: dict | None) -> str | None:
    if not node:
        return None
    if "simpleText" in node:
        return node["simpleText"]
    runs = node.get("runs")
    if isinstance(runs, list):
        text = "".join(r.get("text", "") for r in runs if isinstance(r, dict))
        return text or None
    if "content" in node and isinstance(node["content"], str):
        return node["content"]
    return None


def _lockup_video_id(lv: dict, exclude_id: str | None) -> str | None:
    """Return the usable video id of a lockup view model, or None."""
    content_type = lv.get("contentType")
    if content_type and content_type != "LOCKUP_CONTENT_TYPE_VIDEO":
        return None
    vid = lv.get("contentId")
    if not vid or vid == exclude_id:
        return None
    raw = json.dumps(lv, ensure_ascii=False)
    if '"watchEndpoint"' not in raw:
        return None
    return vid


def _lockup_rows(meta: dict) -> list:
    """Metadata rows of a lockup metadata view model."""
    return (
        meta.get("metadata", {})
        .get("contentMetadataViewModel", {})
        .get("metadataRows", [])
    )


def _lockup_row_info(rows: list) -> dict:
    """Channel, views, views label and age from the lockup metadata rows."""
    info: dict = {
        "channel": None,
        "views": None,
        "views_label": None,
        "age": None,
    }
    if not rows:
        return info
    parts0 = rows[0].get("metadataParts") or []
    if parts0:
        info["channel"] = _runs_text(parts0[0].get("text"))
    if len(rows) > 1:
        parts1 = rows[1].get("metadataParts") or []
        if parts1:
            info["views"] = _runs_text(parts1[0].get("text"))
            info["views_label"] = parts1[0].get("accessibilityLabel")
            if len(parts1) > 1:
                info["age"] = _runs_text(parts1[1].get("text"))
    return info


def _lockup_duration(lv: dict) -> str | None:
    """Duration badge text found in the lockup thumbnail overlays."""
    overlays = (
        lv.get("contentImage", {})
        .get("thumbnailViewModel", {})
        .get("overlays", [])
    )
    for overlay in overlays:
        bottom = overlay.get("thumbnailBottomOverlayViewModel")
        if not bottom:
            continue
        for badge in bottom.get("badges") or []:
            text = (badge.get("thumbnailBadgeViewModel") or {}).get("text") or ""
            if _DURATION_RE.fullmatch(text):
                return text
    return None


def _lockup_item(lv: dict, exclude_id: str | None) -> dict | None:
    vid = _lockup_video_id(lv, exclude_id)
    if not vid:
        return None
    meta = lv.get("metadata", {}).get("lockupMetadataViewModel", {})
    return {
        "id": vid,
        "title": (meta.get("title") or {}).get("content") or "",
        **_lockup_row_info(_lockup_rows(meta)),
        "duration": _lockup_duration(lv),
        "thumbnail": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
    }


def _compact_item(r: dict, exclude_id: str | None) -> dict | None:
    vid = r.get("videoId")
    if not vid or vid == exclude_id:
        return None
    return {
        "id": vid,
        "title": _runs_text(r.get("title")) or "",
        "channel": _runs_text(r.get("longBylineText")) or _runs_text(r.get("shortBylineText")),
        "views": _runs_text(r.get("viewCountText")),
        "views_label": None,
        "age": _runs_text(r.get("publishedTimeText")),
        "duration": _runs_text(r.get("lengthText")),
        "thumbnail": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
    }


def _related_entries(slot: dict) -> list:
    """Expand one secondary-results slot into its candidate renderer dicts."""
    section = slot.get("itemSectionRenderer")
    if isinstance(section, dict):
        inner = section.get("contents")
        if isinstance(inner, list):
            return inner
    return [slot]


def _related_entry_item(entry: dict, exclude_id: str | None) -> dict | None:
    """Convert one compact/lockup renderer into a compact item dict."""
    if "lockupViewModel" in entry:
        return _lockup_item(entry["lockupViewModel"], exclude_id)
    if "compactVideoRenderer" in entry:
        return _compact_item(entry["compactVideoRenderer"], exclude_id)
    return None


def _add_related(items: list[dict], seen: set[str], item: dict | None) -> None:
    """Append a related item once, keeping only titled and unseen videos."""
    if not item or not item["title"] or item["id"] in seen:
        return
    seen.add(item["id"])
    items.append(item)


def parse_related(initial: dict, exclude_id: str | None = None) -> list[dict]:
    try:
        results = (
            initial.get("contents", {})
            .get("twoColumnWatchNextResults", {})
            .get("secondaryResults", {})
            .get("secondaryResults", {})
            .get("results", [])
        )
    except AttributeError:
        return []

    items: list[dict] = []
    seen: set[str] = set()

    for slot in results:
        if not isinstance(slot, dict):
            continue
        for entry in _related_entries(slot):
            if not isinstance(entry, dict):
                continue
            _add_related(items, seen, _related_entry_item(entry, exclude_id))
    return items


def extract_comment_token(next_payload: dict) -> str | None:
    panels = next_payload.get("engagementPanels") or []
    for panel in panels:
        ep = panel.get("engagementPanelSectionListRenderer") or {}
        ident = str(ep.get("panelIdentifier") or "")
        if _COMMENT_PANEL_HINT not in ident:
            continue
        raw = json.dumps(ep, ensure_ascii=False)
        m = re.search(r'"continuationCommand":\s*{\s*"token":\s*"([^"]+)"', raw)
        if m:
            return m.group(1)
    return None


def _comment_entities(next_payload: dict) -> dict[str, dict]:
    """Index comment entity payloads by their entity key."""
    entities: dict[str, dict] = {}
    updates = next_payload.get("frameworkUpdates") or {}
    mutations = (updates.get("entityBatchUpdate") or {}).get("mutations") or []
    for mutation in mutations:
        payload = mutation.get("payload") or {}
        entity = payload.get("commentEntityPayload")
        if entity and mutation.get("entityKey"):
            entities[mutation["entityKey"]] = entity
    return entities


def _continuation_token(renderer: dict) -> str | None:
    """Continuation token inside a continuationItemRenderer."""
    return (
        renderer.get("continuationEndpoint", {})
        .get("continuationCommand", {})
        .get("token")
    )


def _comment_threads(next_payload: dict) -> tuple[list[dict], str | None]:
    """Comment thread renderers plus the next-page token, if any."""
    threads: list[dict] = []
    next_token: str | None = None
    for endpoint in next_payload.get("onResponseReceivedEndpoints") or []:
        command = (
            endpoint.get("reloadContinuationItemsCommand")
            or endpoint.get("appendContinuationItemsAction")
            or {}
        )
        if "comment" not in str(command.get("targetId") or ""):
            continue
        for item in command.get("continuationItems") or []:
            if "commentThreadRenderer" in item:
                threads.append(item["commentThreadRenderer"])
            elif "continuationItemRenderer" in item:
                token = _continuation_token(item["continuationItemRenderer"])
                if token:
                    next_token = token
    return threads, next_token


def _comment_item(thread: dict, entities: dict[str, dict]) -> dict | None:
    """Map one comment thread renderer to our comment dict, or None."""
    vm = ((thread.get("commentViewModel") or {}).get("commentViewModel")) or {}
    entity = entities.get(vm.get("commentKey"))
    if not entity:
        return None
    props = entity.get("properties") or {}
    text = (props.get("content") or {}).get("content") or ""
    if not text:
        return None
    author = entity.get("author") or {}
    toolbar = entity.get("toolbar") or {}
    return {
        "author": author.get("displayName") or "",
        "avatar": author.get("avatarThumbnailUrl"),
        "text": text,
        "published": props.get("publishedTime"),
        "likes": toolbar.get("likeCountNotliked"),
        "replies": toolbar.get("replyCount"),
        "verified": bool(author.get("isVerified")),
        "pinned_text": vm.get("pinnedText"),
    }


def parse_comments(next_payload: dict) -> tuple[list[dict], str | None]:
    entities = _comment_entities(next_payload)
    threads, next_token = _comment_threads(next_payload)
    items: list[dict] = []
    for thread in threads:
        item = _comment_item(thread, entities)
        if item:
            items.append(item)
    return items, next_token


def _bundle(video_id: str) -> dict:
    if not _VIDEO_ID_RE.fullmatch(video_id or ""):
        raise WatchError(400, "Invalid video id")
    return {
        **_STATIC_CONFIG,
        "video_id": video_id,
        "watch_url": f"https://www.youtube.com/watch?v={video_id}",
    }


def _post_next(bundle: dict, payload: dict) -> dict:
    from curl_cffi import requests as cffi_requests

    url = "https://www.youtube.com/youtubei/v1/next?prettyPrint=false"
    client_version = (
        bundle["context"].get("client", {}).get("clientVersion", "")
    )
    headers = {
        "Content-Type": "application/json",
        "Origin": "https://www.youtube.com",
        "X-Youtube-Client-Name": "1",
        "X-Youtube-Client-Version": client_version,
        **_UA_COOKIES,
    }
    visitor = bundle.get("visitor") or ""
    if visitor:
        headers["X-Goog-Visitor-Id"] = visitor
    try:
        resp = cffi_requests.post(
            url,
            json=payload,
            headers=headers,
            impersonate="chrome",
            timeout=20,
        )
    except Exception as exc:
        raise WatchError(502, f"YouTube API request failed: {exc}") from exc
    if resp.status_code >= 400:
        snippet = (resp.text or "")[:300]
        raise WatchError(502, f"YouTube API HTTP {resp.status_code}: {snippet}")
    return resp.json()


def _safe_invidious_path(path: str) -> str:
    """Validate an Invidious API path, rejecting traversal and URL injection.

    Only relative paths made of whitelisted single-level segments are
    accepted; `..`, empty segments, absolute URLs and any other character
    outside ``[A-Za-z0-9._~-]`` raise a 400 instead of reaching the network.
    """
    if not isinstance(path, str):
        raise WatchError(400, "Invalid invidious path")
    raw_path, _, query = path.partition("?")
    segments = raw_path.split("/")[1:]
    if not raw_path.startswith("/") or not segments:
        raise WatchError(400, "Invalid invidious path")
    safe_segments: list[str] = []
    for segment in segments:
        if segment in ("", ".", ".."):
            raise WatchError(400, "Invalid invidious path")
        if not _INVIDIOUS_SEGMENT_RE.fullmatch(segment):
            raise WatchError(400, "Invalid invidious path")
        safe_segments.append(urllib.parse.quote(segment, safe=""))
    safe = "/" + "/".join(safe_segments)
    if query:
        if not _INVIDIOUS_QUERY_RE.fullmatch(query):
            raise WatchError(400, "Invalid invidious path")
        safe = f"{safe}?{query}"
    return safe


def _invidious_get(
    path: str, params: dict | None = None, timeout: float = 20
) -> dict:
    safe_path = _safe_invidious_path(path)
    last: Exception | None = None
    for base in _INVIDIOUS_BASES:
        url = f"{base}{safe_path}"
        if params:
            url = f"{url}?{urllib.parse.urlencode(params)}"
        try:
            req = urllib.request.Request(
                url,
                headers={"User-Agent": _BROWSER_UA, "Accept": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read())
        except Exception as exc:  # noqa: BLE001 - collect and report last error
            last = exc
    raise WatchError(502, f"invidious fallback failed: {last}")


def _fmt_duration(seconds: int) -> str | None:
    if seconds <= 0:
        return None
    hours, rem = divmod(seconds, 3600)
    minutes, secs = divmod(rem, 60)
    if hours:
        return f"{hours}:{minutes:02d}:{secs:02d}"
    return f"{minutes}:{secs:02d}"


def _invidious_related(video_id: str) -> list[dict]:
    logger.info(f"Invidious related fallback for {video_id}")
    data = _invidious_get(f"/api/v1/videos/{video_id}")
    items: list[dict] = []
    for v in data.get("recommendedVideos") or []:
        vid = v.get("videoId")
        title = v.get("title") or ""
        if not vid or vid == video_id or not title:
            continue
        try:
            length = int(v.get("lengthSeconds") or 0)
        except (TypeError, ValueError):
            length = 0
        items.append(
            {
                "id": vid,
                "title": title,
                "channel": v.get("author"),
                "views": v.get("viewCountText"),
                "views_label": None,
                "age": v.get("publishedText"),
                "duration": _fmt_duration(length),
                "thumbnail": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
            }
        )
    if not items:
        raise WatchError(502, "invidious returned no related videos")
    return items


def _invidious_map_comments(data: dict) -> list[dict]:
    items: list[dict] = []
    for c in data.get("comments") or []:
        text = c.get("content") or ""
        if not text:
            continue
        author = c.get("author") or ""
        try:
            likes_int = int(c.get("likeCount") or 0)
        except (TypeError, ValueError):
            likes_int = 0
        items.append(
            {
                "author": author,
                "avatar": c.get("authorThumbnail"),
                "text": text,
                "published": c.get("publishedText"),
                "likes": _format_count(likes_int) if likes_int else None,
                "replies": None,
                "verified": bool(c.get("verified")),
                "pinned_text": (
                    f"Pinned by {author}" if c.get("isPinned") else None
                ),
            }
        )
    return items


def _invidious_comments(video_id: str) -> tuple[list[dict], str | None]:
    logger.info(f"Invidious comments fallback for {video_id}")
    data = _invidious_get(f"/api/v1/comments/{video_id}")
    items = _invidious_map_comments(data)
    cont = data.get("continuation")
    return items, f"iv:{cont}" if cont else None


def get_related(video_id: str) -> list[dict]:
    global _NEXT_FAIL_UNTIL

    cache_key = f"related:{video_id}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    items: list[dict] = []
    fallback = False
    if time.time() < _NEXT_FAIL_UNTIL:
        logger.info("Innertube recently blocked, going straight to fallback")
        fallback = True
    else:
        try:
            bundle = _bundle(video_id)
            payload = _post_next(
                bundle, {"context": bundle["context"], "videoId": video_id}
            )
            items = parse_related(payload, exclude_id=video_id)
            _NEXT_FAIL_UNTIL = 0.0
        except WatchError as exc:
            _NEXT_FAIL_UNTIL = time.time() + _NEXT_FAIL_TTL
            logger.warning(f"Innertube related failed ({exc.detail[:80]})")
            fallback = True
    if fallback:
        items = _invidious_related(video_id)

    _cache_put(cache_key, items, _TTL_RELATED)
    logger.info(f"Related for {video_id}: {len(items)} items")
    return items


def _format_count(n: int) -> str:
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M".replace(".0M", "M")
    if n >= 1_000:
        return f"{n / 1_000:.1f}K".replace(".0K", "K")
    return str(n)


def _yt_dlp_comments(video_id: str) -> tuple[list[dict], str | None]:
    """Fallback when innertube /next is blocked (403 from datacenter IPs)."""
    import subprocess

    from app.core.config import settings

    # Strict whitelist check before the id reaches a subprocess argument.
    if not _VIDEO_ID_RE.fullmatch(video_id or ""):
        raise WatchError(400, "Invalid video id")
    watch_url = "https://www.youtube.com/watch?" + urllib.parse.urlencode(
        {"v": video_id}
    )
    # Arguments are a fixed list of constants plus one validated id: no shell
    # string is ever built, so the value cannot inject extra arguments.
    cmd = [
        settings.YT_DLP_PATH,
        "--skip-download",
        "--write-comments",
        "--extractor-args",
        "youtube:max_comments=20,all,all;comment_sort=top",
        "--dump-single-json",
        watch_url,
    ]
    logger.info(f"yt-dlp comments fallback for {video_id}")
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    if result.returncode != 0:
        raise WatchError(
            502, f"yt-dlp comments error: {result.stderr.strip()[:200]}"
        )
    data = json.loads(result.stdout or "{}")
    items: list[dict] = []
    for c in (data.get("comments") or [])[:20]:
        text = c.get("text") or ""
        if not text:
            continue
        likes = c.get("like_count")
        author = c.get("author") or ""
        items.append(
            {
                "author": author,
                "avatar": c.get("author_thumbnail"),
                "text": text,
                "published": c.get("_time_text"),
                "likes": _format_count(int(likes)) if likes else None,
                "replies": None,
                "verified": bool(c.get("author_is_verified")),
                "pinned_text": (
                    f"Pinned by {author}" if c.get("is_pinned") else None
                ),
            }
        )
    return items, None


_IT_LAST_ERR = ""


def _innertube_android(video_id: str) -> dict:
    """YouTube innertube player via the ANDROID client (TLS-impersonated).

    Works from datacenter IPs where the web client is rejected, and needs
    no third-party instance. Returns {} on any failure.
    """
    global _IT_LAST_ERR
    from curl_cffi import requests as cffi_requests

    payload = {
        "videoId": video_id,
        "contentCheckOk": True,
        "racyCheckOk": True,
        "context": {
            "client": {
                "clientName": "ANDROID",
                "clientVersion": "20.10.38",
                "androidSdkVersion": 30,
                "hl": "en",
                "gl": "US",
            }
        },
    }
    try:
        r = cffi_requests.post(
            "https://www.youtube.com/youtubei/v1/player?prettyPrint=false",
            json=payload,
            impersonate="chrome",
            timeout=25,
        )
        if r.status_code != 200:
            _IT_LAST_ERR = f"player http {r.status_code}: {r.text[:120]!r}"
            logger.info(f"innertube player HTTP {r.status_code} for {video_id}")
            return {}
        data = r.json()
    except Exception as e:  # noqa: BLE001
        _IT_LAST_ERR = f"player exc {e!r}"[:200]
        logger.info(f"innertube player failed for {video_id}: {e}")
        return {}
    status = data.get("playabilityStatus") or {}
    if status.get("status") != "OK":
        _IT_LAST_ERR = f"playability {status.get('status')}: {status.get('reason')!r}"[:200]
        logger.info(f"innertube playability not OK: {status.get('reason')}")
        return {}
    _IT_LAST_ERR = ""
    return data


def _media_height(f: dict) -> int:
    try:
        return int(f.get("height") or 0)
    except (TypeError, ValueError):
        return 0


def _media_bitrate(f: dict) -> int:
    try:
        return int(f.get("bitrate") or 0)
    except (TypeError, ValueError):
        return 0


def _pick_smallest_or_lowest(
    cands: list[dict], height: Callable[[dict], int]
) -> dict | None:
    """Best format <=480p, or the lowest resolution when none is small."""
    if not cands:
        return None
    small = [f for f in cands if 0 < height(f) <= 480]
    pool = sorted(small or cands, key=height)
    return pool[-1] if small else pool[0]


def _pick_highest_bitrate(cands: list[dict]) -> dict | None:
    if not cands:
        return None
    return sorted(cands, key=_media_bitrate)[-1]


def _innertube_formats(sd: dict, mime: str, codec: str | None = None) -> list[dict]:
    """Innertube adaptive formats that have a url and match mime (and codec)."""
    out: list[dict] = []
    for f in sd.get("adaptiveFormats") or []:
        mime_type = f.get("mimeType") or ""
        if not f.get("url") or mime not in mime_type:
            continue
        if codec is not None and codec not in mime_type:
            continue
        out.append(f)
    return out


def _innertube_pick(video_id: str) -> dict:
    """Extract muxed/adaptive urls + video details from the innertube player."""
    d = _innertube_android(video_id)
    if not d:
        return {}
    sd = d.get("streamingData") or {}
    details = d.get("videoDetails") or {}
    out: dict = {"details": details}

    muxed = _pick_smallest_or_lowest(
        [f for f in (sd.get("formats") or []) if f.get("url")], _media_height
    )
    if muxed:
        out["muxed"] = muxed.get("url")

    video = _pick_smallest_or_lowest(
        _innertube_formats(sd, "video/mp4", "avc1"), _media_height
    )
    if video:
        out["video"] = video.get("url")

    audio = _pick_highest_bitrate(_innertube_formats(sd, _AUDIO_MIME_PREFIX))
    if audio:
        out["audio"] = audio.get("url")
    return out


def _relay_warm_kick(video_id: str) -> None:
    """Start the background merge for non-muxed videos (best effort).

    Runs in a thread: may fetch sources fresh if innertube returned nothing
    during the stream-url call, without slowing down that response.
    """

    def _go() -> None:
        try:
            pair = _cache_get(f"relay:{video_id}")
            if not pair or not pair.get("video") or not pair.get("audio"):
                pair = get_relay_sources(video_id)
            relay_warm.start(video_id, pair)
            relay_warm._last_err[video_id] = None
        except Exception as exc:  # noqa: BLE001
            logger.info(f"relay warm skipped for {video_id}: {exc}")
            relay_warm._last_err[video_id] = f"kick: {exc}"[:200]

    threading.Thread(target=_go, daemon=True).start()


def _to_int(value) -> int:
    try:
        return int(value)
    except (TypeError, ValueError):
        return 0


def _stream_defaults() -> dict:
    """Empty stream-url result, filled in from innertube and/or Invidious."""
    return {
        "video": None,
        "audio": None,
        "title": None,
        "channel": None,
        "duration": None,
        "description": None,
        "channel_avatar": None,
        "comment_count": None,
    }


def _stream_from_innertube(video_id: str, it: dict) -> dict:
    """Video/audio urls and video details from an innertube player payload."""
    det = it.get("details") or {}
    fields = _stream_defaults()
    fields["video"] = it.get("muxed")
    fields["audio"] = it.get("audio")
    fields["title"] = det.get("title")
    fields["channel"] = det.get("author")
    fields["duration"] = _to_int(det.get("lengthSeconds")) or None
    fields["description"] = (det.get("shortDescription") or "")[:500] or None
    # Seed the relay cache so /relay never waits on Invidious.
    if it.get("video") and it.get("audio"):
        _cache_put(
            f"relay:{video_id}",
            {"video": it["video"], "audio": it["audio"]},
            900,
        )
    return fields


def _invidious_muxed_url(data: dict) -> str | None:
    """Highest-itag progressive mp4 url from an Invidious payload."""
    muxed = [
        f
        for f in (data.get("formatStreams") or [])
        if f.get("url") and "mp4" in (f.get("container") or f.get("type") or "")
    ]
    if not muxed:
        return None
    muxed.sort(key=lambda f: _to_int(f.get("itag")))
    return muxed[-1].get("url")


def _invidious_audio_url(data: dict) -> str | None:
    """Highest-bitrate audio url from an Invidious payload (mp4 preferred)."""
    audio_fmts = [
        f
        for f in (data.get("adaptiveFormats") or [])
        if f.get("url") and (f.get("type") or "").startswith(_AUDIO_MIME_PREFIX)
    ]
    if not audio_fmts:
        return None
    mp4_audio = [
        f for f in audio_fmts if "mp4" in (f.get("type") or "").lower()
    ]
    pool = mp4_audio or audio_fmts
    pool.sort(key=lambda f: _to_int(f.get("bitrate")))
    return pool[-1].get("url")


def _apply_invidious_metadata(fields: dict, data: dict) -> None:
    """Fill missing stream fields from an Invidious /videos payload."""
    if not fields["video"]:
        fields["video"] = _invidious_muxed_url(data)
    if not fields["audio"]:
        fields["audio"] = _invidious_audio_url(data)
    avatars = data.get("authorThumbnails") or []
    fields["channel_avatar"] = avatars[-1].get("url") if avatars else None
    comment_count = data.get("commentCount")
    if comment_count is not None:
        comment_count = _to_int(comment_count) or None
    fields["comment_count"] = comment_count
    fields["title"] = fields["title"] or data.get("title")
    fields["channel"] = fields["channel"] or data.get("author")
    length = _to_int(data.get("lengthSeconds")) or None
    fields["duration"] = fields["duration"] or length
    if not fields["description"]:
        fields["description"] = (data.get("description") or "")[:500] or None


def _stream_result(fields: dict) -> dict:
    """Public stream-url payload built from the collected fields."""
    return {
        "video": fields["video"],
        "audio": fields["audio"],
        "proxy": (
            "/api/explore/proxy?u="
            + urllib.parse.quote(fields["video"], safe="")
            if fields["video"]
            else None
        ),
        "title": fields["title"],
        "channel": fields["channel"],
        "channel_avatar": fields["channel_avatar"],
        "comment_count": fields["comment_count"],
        "duration": fields["duration"],
        "description": fields["description"],
    }


def _warm_anubis(warm_url: str | None) -> None:
    """Pre-solve the anti-bot cookie in the background (best effort)."""
    if not warm_url or ".f5.si" not in warm_url:
        return

    def _warm() -> None:
        try:
            from app.services.anubis_client import cookie_header

            cookie_header(warm_url)
        except Exception as exc:  # noqa: BLE001
            logger.info(f"anubis warmup skipped: {exc}")

    threading.Thread(target=_warm, daemon=True).start()


def get_stream_urls(video_id: str) -> dict:
    """Playable stream URLs + channel/comment metadata.

    Primary source: our own innertube request (no third-party dependency).
    Invidious fills in avatar/comment count and acts as fallback.
    """
    cache_key = f"stream:{video_id}"
    cached = _cache_get(cache_key)
    if cached is not None:
        if not cached.get("video"):
            _relay_warm_kick(video_id)
        return cached

    fields = _stream_defaults()
    # The innertube request and the Invidious metadata call are independent:
    # running them one after the other put both round trips (2-3s of a cold
    # play) in front of the first frame. Started together, the wait is the
    # slowest of the two instead of the sum.
    with ThreadPoolExecutor(max_workers=2) as pool:
        innertube_future = pool.submit(_innertube_pick, video_id)
        invidious_future = pool.submit(
            _invidious_get, f"/api/v1/videos/{video_id}?local=true"
        )
        try:
            it = innertube_future.result()
        except Exception as e:  # noqa: BLE001
            logger.info(f"innertube pick failed for {video_id}: {e}")
            it = None
        if it:
            fields = _stream_from_innertube(video_id, it)

        # Invidious: avatar, comment count and any missing urls (best effort).
        try:
            data = invidious_future.result()
            _apply_invidious_metadata(fields, data)
        except Exception as e:  # noqa: BLE001
            logger.info(f"invidious metadata unavailable for {video_id}: {e}")
            if not fields["video"] and not fields["audio"]:
                raise WatchError(
                    502,
                    f"all stream sources failed — innertube: {_IT_LAST_ERR or 'empty'}"
                    f" | invidious: {str(e)[:120]}",
            ) from e

    if not fields["video"] and not fields["audio"]:
        raise WatchError(502, "no stream urls")

    result = _stream_result(fields)
    _cache_put(cache_key, result, 900)
    logger.info(
        f"Stream urls for {video_id}: video={bool(fields['video'])}"
        f" audio={bool(fields['audio'])}"
    )

    # No muxed format → playback will go through /relay. Start the merge
    # NOW while the user is still on the video card: by the time they press
    # play the first bytes are buffered (ExoPlayer aborts after 8s).
    if not fields["video"]:
        _relay_warm_kick(video_id)

    # Pre-solve the anti-bot cookie in the background while the user is
    # still looking at the video card, so pressing play doesn't wait for it.
    _warm_anubis(fields["video"] or fields["audio"])

    return result


def _quality_height(f: dict) -> int:
    """Height from Invidious format fields (height or qualityLabel)."""
    try:
        return int(str(f.get("height") or f.get("qualityLabel") or "0").strip("p"))
    except (TypeError, ValueError):
        return 0


def _invidious_formats(data: dict, mime: str, codec: str | None = None) -> list[dict]:
    """Invidious adaptive formats that have a url and match mime (and codec)."""
    out: list[dict] = []
    for f in data.get("adaptiveFormats") or []:
        mime_type = f.get("type") or ""
        if not f.get("url") or mime not in mime_type:
            continue
        if codec is not None and codec not in mime_type:
            continue
        out.append(f)
    return out


def get_relay_sources(video_id: str) -> dict:
    """Adaptive video+audio URLs for server-side ffmpeg merge (/relay).

    Many videos have no muxed format (formatStreams empty); those can only
    be played by merging video and audio. The merge happens on our server so
    the phone only needs to reach us.
    """
    cache_key = f"relay:{video_id}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    # Primary: adaptive pair from our own innertube request (seeded earlier
    # by get_stream_urls, or fetched here as a fallback).
    it = _innertube_pick(video_id)
    if it and it.get("video") and it.get("audio"):
        result = {"video": it["video"], "audio": it["audio"]}
        _cache_put(cache_key, result, 900)
        logger.info(f"Relay sources (innertube) for {video_id}")
        return result

    # Fallback: Invidious adaptive formats (local=true so ffmpeg pulls from
    # the instance instead of googlevideo).
    data = _invidious_get(f"/api/v1/videos/{video_id}?local=true")

    video_cands = _invidious_formats(data, "video/mp4", "avc1")
    if not video_cands:
        raise WatchError(502, "no mp4 video format")
    video = _pick_smallest_or_lowest(video_cands, _quality_height)

    audio_cands = _invidious_formats(data, "audio/mp4")
    if not audio_cands:
        audio_cands = _invidious_formats(data, _AUDIO_MIME_PREFIX)
    if not audio_cands:
        raise WatchError(502, "no audio format")
    audio = _pick_highest_bitrate(audio_cands)

    result = {"video": video.get("url"), "audio": audio.get("url")}
    _cache_put(cache_key, result, 900)
    logger.info(
        f"Relay sources for {video_id}: v={_quality_height(video)}p "
        f"vlen={len(video.get('url') or '')} alen={len(audio.get('url') or '')}"
    )
    return result


def get_play_url(video_id: str) -> dict:
    """Relay info: server-side yt-dlp format for /api/fetch streaming.

    Used when the phone cannot reach googlevideo directly: the app plays
    through our /api/fetch relay (server -> YouTube -> phone).
    """
    cache_key = f"play:{video_id}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    from app.services.extractor_service import extract_info

    watch_url = f"https://www.youtube.com/watch?v={video_id}"
    try:
        data = extract_info(watch_url)
    except Exception as exc:  # noqa: BLE001 - surface as WatchError
        raise WatchError(502, str(exc)[:400]) from exc

    fmts = data.get("formats") or []
    progressive = [
        f
        for f in fmts
        if f.get("acodec")
        and f.get("acodec") != "none"
        and f.get("vcodec")
        and f.get("vcodec") != "none"
        and f.get("ext") == "mp4"
    ]
    small = [f for f in progressive if (f.get("height") or 9999) <= 480]
    pool = small or progressive
    if not pool:
        raise WatchError(502, "no progressive format available")
    pool.sort(key=lambda f: (f.get("height") or 0))
    chosen = pool[-1]

    result = {
        "url": watch_url,
        "format_id": str(chosen.get("format_id")),
        "ext": str(chosen.get("ext") or "mp4"),
        "height": chosen.get("height"),
    }
    _cache_put(cache_key, result, 900)
    logger.info(f"Play url for {video_id}: format={result['format_id']}")
    return result


def _invidious_comment_page(
    video_id: str, continuation: str
) -> tuple[list[dict], str | None]:
    """Next comment page from Invidious using an 'iv:' continuation token."""
    data = _invidious_get(
        f"/api/v1/comments/{video_id}", {"continuation": continuation}
    )
    items = _invidious_map_comments(data)
    cont = data.get("continuation")
    return items, f"iv:{cont}" if cont else None


def _first_comment_page(video_id: str) -> tuple[list[dict], str | None] | None:
    """First innertube comment page.

    Returns None when the watch payload exposes no comment continuation.
    """
    global _NEXT_FAIL_UNTIL

    bundle = _bundle(video_id)
    first = _post_next(bundle, {"context": bundle["context"], "videoId": video_id})
    _NEXT_FAIL_UNTIL = 0.0
    comment_token = extract_comment_token(first)
    if not comment_token:
        return None
    payload = _post_next(
        bundle, {"context": bundle["context"], "continuation": comment_token}
    )
    return parse_comments(payload)


def _next_comment_page(video_id: str, token: str) -> tuple[list[dict], str | None]:
    """Continuation page for a comment token issued by innertube."""
    global _NEXT_FAIL_UNTIL

    bundle = _bundle(video_id)
    payload = _post_next(bundle, {"context": bundle["context"], "continuation": token})
    _NEXT_FAIL_UNTIL = 0.0
    return parse_comments(payload)


def _comments_fallback(video_id: str) -> tuple[list[dict], str | None]:
    """Invidious comments, then yt-dlp, when innertube cannot serve them."""
    try:
        return _invidious_comments(video_id)
    except WatchError as exc:
        logger.warning(
            f"Invidious comments failed ({exc.detail[:60]}), trying yt-dlp"
        )
        return _yt_dlp_comments(video_id)


def get_comments(video_id: str, token: str | None = None) -> tuple[list[dict], str | None]:
    global _NEXT_FAIL_UNTIL

    cache_key = f"comments:{video_id}:{token or ''}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    # Continuation token issued by the invidious fallback -> stay there.
    if token and token.startswith("iv:"):
        items, next_token = _invidious_comment_page(video_id, token[3:])
        _cache_put(cache_key, (items, next_token), _TTL_COMMENTS)
        logger.info(f"Comments for {video_id}: {len(items)} items (fallback page)")
        return items, next_token

    items: list[dict] = []
    next_token: str | None = None
    fallback = False
    if time.time() < _NEXT_FAIL_UNTIL and not token:
        logger.info("Innertube recently blocked, going straight to fallback")
        fallback = True
    else:
        try:
            page = (
                _next_comment_page(video_id, token)
                if token
                else _first_comment_page(video_id)
            )
            if page is None:
                _cache_put(cache_key, ([], None), _TTL_COMMENTS)
                return [], None
            items, next_token = page
        except WatchError as exc:
            _NEXT_FAIL_UNTIL = time.time() + _NEXT_FAIL_TTL
            logger.warning(f"Innertube comments failed ({exc.detail[:80]})")
            if token:
                raise  # cannot continue an innertube page from another source
            fallback = True

    if fallback:
        items, next_token = _comments_fallback(video_id)

    _cache_put(cache_key, (items, next_token), _TTL_COMMENTS)
    logger.info(f"Comments for {video_id}: {len(items)} items")
    return items, next_token
