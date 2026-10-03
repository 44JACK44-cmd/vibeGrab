import json
import re
import threading
import time
import urllib.parse
import urllib.request

from app.core.logging import logger

_UA_COOKIES = {
    "Cookie": "CONSENT=YES+cb.20210328-17-p0.en+FX+000; SOCS=CAI",
    "Accept-Language": "en-US,en;q=0.9",
}
# Static innertube config. clientVersion must match yt-dlp's real WEB value
# and (like yt-dlp) we omit ?key= and never send an empty X-Goog-Visitor-Id.
# Even so, YouTube answers 403 ("Sorry..." bot page) to /next from datacenter
# IPs (Render), so get_related/get_comments fall back to a Invidious instance
# (which fetches YouTube from its own IP) and then to yt-dlp.
_STATIC_CONFIG = {
    "api_key": "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
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

_YT_INITIAL_RE = re.compile(r"var ytInitialData = ({.+?});</script>", re.S)
_API_KEY_RE = re.compile(r'"INNERTUBE_API_KEY":"([^"]+)"')
_VISITOR_RE = re.compile(r'"VISITOR_DATA":"([^"]+)"')
_DURATION_RE = re.compile(r"\d+(?::\d+)+$")
_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")
_COMMENT_PANEL_HINT = "comment"

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


def _lockup_item(lv: dict, exclude_id: str | None) -> dict | None:
    content_type = lv.get("contentType")
    if content_type and content_type != "LOCKUP_CONTENT_TYPE_VIDEO":
        return None
    vid = lv.get("contentId")
    if not vid or vid == exclude_id:
        return None
    raw = json.dumps(lv, ensure_ascii=False)
    if '"watchEndpoint"' not in raw:
        return None

    meta = lv.get("metadata", {}).get("lockupMetadataViewModel", {})
    title = (meta.get("title") or {}).get("content") or ""

    channel = None
    views = None
    views_label = None
    age = None
    rows = (
        meta.get("metadata", {})
        .get("contentMetadataViewModel", {})
        .get("metadataRows", [])
    )
    if rows:
        parts0 = rows[0].get("metadataParts") or []
        if parts0:
            channel = _runs_text(parts0[0].get("text"))
    if len(rows) > 1:
        parts1 = rows[1].get("metadataParts") or []
        if parts1:
            views = _runs_text(parts1[0].get("text"))
            views_label = parts1[0].get("accessibilityLabel")
            if len(parts1) > 1:
                age = _runs_text(parts1[1].get("text"))

    duration = None
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
                duration = text
                break
        if duration:
            break

    return {
        "id": vid,
        "title": title,
        "channel": channel,
        "views": views,
        "views_label": views_label,
        "age": age,
        "duration": duration,
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

    def _add(item: dict | None) -> None:
        if item and item["id"] not in seen and item["title"]:
            seen.add(item["id"])
            items.append(item)

    for slot in results:
        if not isinstance(slot, dict):
            continue
        entries = [slot]
        section = slot.get("itemSectionRenderer")
        if isinstance(section, dict):
            inner = section.get("contents")
            if isinstance(inner, list):
                entries = inner
        for entry in entries:
            if not isinstance(entry, dict):
                continue
            if "lockupViewModel" in entry:
                _add(_lockup_item(entry["lockupViewModel"], exclude_id))
            elif "compactVideoRenderer" in entry:
                _add(_compact_item(entry["compactVideoRenderer"], exclude_id))
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


def parse_comments(next_payload: dict) -> tuple[list[dict], str | None]:
    entities: dict[str, dict] = {}
    updates = next_payload.get("frameworkUpdates") or {}
    for mutation in (updates.get("entityBatchUpdate") or {}).get("mutations") or []:
        payload = mutation.get("payload") or {}
        entity = payload.get("commentEntityPayload")
        if entity and mutation.get("entityKey"):
            entities[mutation["entityKey"]] = entity

    items: list[dict] = []
    next_token: str | None = None
    threads: list[dict] = []
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
                token = (
                    item["continuationItemRenderer"]
                    .get("continuationEndpoint", {})
                    .get("continuationCommand", {})
                    .get("token")
                )
                if token:
                    next_token = token

    for thread in threads:
        vm = ((thread.get("commentViewModel") or {}).get("commentViewModel")) or {}
        entity = entities.get(vm.get("commentKey"))
        if not entity:
            continue
        props = entity.get("properties") or {}
        author = entity.get("author") or {}
        toolbar = entity.get("toolbar") or {}
        text = (props.get("content") or {}).get("content") or ""
        if not text:
            continue
        items.append(
            {
                "author": author.get("displayName") or "",
                "avatar": author.get("avatarThumbnailUrl"),
                "text": text,
                "published": props.get("publishedTime"),
                "likes": toolbar.get("likeCountNotliked"),
                "replies": toolbar.get("replyCount"),
                "verified": bool(author.get("isVerified")),
                "pinned_text": vm.get("pinnedText"),
            }
        )
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


def _invidious_get(
    path: str, params: dict | None = None, timeout: float = 20
) -> dict:
    last: Exception | None = None
    for base in _INVIDIOUS_BASES:
        url = f"{base}{path}"
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

    cmd = [
        settings.YT_DLP_PATH,
        "--skip-download",
        "--write-comments",
        "--extractor-args",
        "youtube:max_comments=20,all,all;comment_sort=top",
        "--dump-single-json",
        f"https://www.youtube.com/watch?v={video_id}",
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


def get_stream_urls(video_id: str) -> dict:
    """Playable stream URLs (via Invidious) + channel/comment metadata.

    googlevideo URLs obtained this way are NOT IP-locked, so the phone can
    play them directly — this is the playback fallback when YouTube blocks
    the device-side youtube_explode request.
    """
    cache_key = f"stream:{video_id}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    data = _invidious_get(f"/api/v1/videos/{video_id}")

    def _int(v) -> int:
        try:
            return int(v)
        except (TypeError, ValueError):
            return 0

    video_url = None
    muxed = [
        f
        for f in (data.get("formatStreams") or [])
        if f.get("url") and "mp4" in (f.get("container") or f.get("type") or "")
    ]
    if muxed:
        muxed.sort(key=lambda f: _int(f.get("itag")))
        video_url = muxed[-1].get("url")

    audio_url = None
    audio_fmts = [
        f
        for f in (data.get("adaptiveFormats") or [])
        if f.get("url") and (f.get("type") or "").startswith("audio/")
    ]
    if audio_fmts:
        mp4_audio = [
            f for f in audio_fmts if "mp4" in (f.get("type") or "").lower()
        ]
        pool = mp4_audio or audio_fmts
        pool.sort(key=lambda f: _int(f.get("bitrate")))
        audio_url = pool[-1].get("url")

    if not video_url and not audio_url:
        raise WatchError(502, "invidious returned no stream urls")

    avatars = data.get("authorThumbnails") or []
    channel_avatar = avatars[-1].get("url") if avatars else None

    comment_count = data.get("commentCount")
    if comment_count is not None:
        comment_count = _int(comment_count) or None

    result = {
        "video": video_url,
        "audio": audio_url,
        "title": data.get("title"),
        "channel": data.get("author"),
        "channel_avatar": channel_avatar,
        "comment_count": comment_count,
        "duration": _int(data.get("lengthSeconds")) or None,
        "description": (data.get("description") or "")[:500],
    }
    _cache_put(cache_key, result, 900)
    logger.info(f"Stream urls for {video_id}: video={bool(video_url)} audio={bool(audio_url)}")
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


def get_comments(video_id: str, token: str | None = None) -> tuple[list[dict], str | None]:
    global _NEXT_FAIL_UNTIL

    cache_key = f"comments:{video_id}:{token or ''}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    # Continuation token issued by the invidious fallback -> stay there.
    if token and token.startswith("iv:"):
        data = _invidious_get(
            f"/api/v1/comments/{video_id}", {"continuation": token[3:]}
        )
        items = _invidious_map_comments(data)
        cont = data.get("continuation")
        next_token = f"iv:{cont}" if cont else None
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
            bundle = _bundle(video_id)
            if token:
                next_payload = _post_next(
                    bundle, {"context": bundle["context"], "continuation": token}
                )
                _NEXT_FAIL_UNTIL = 0.0
                items, next_token = parse_comments(next_payload)
            else:
                first = _post_next(
                    bundle, {"context": bundle["context"], "videoId": video_id}
                )
                _NEXT_FAIL_UNTIL = 0.0
                comment_token = extract_comment_token(first)
                if not comment_token:
                    _cache_put(cache_key, ([], None), _TTL_COMMENTS)
                    return [], None
                next_payload = _post_next(
                    bundle, {"context": bundle["context"], "continuation": comment_token}
                )
                items, next_token = parse_comments(next_payload)
        except WatchError as exc:
            _NEXT_FAIL_UNTIL = time.time() + _NEXT_FAIL_TTL
            logger.warning(f"Innertube comments failed ({exc.detail[:80]})")
            if token:
                raise  # cannot continue an innertube page from another source
            fallback = True

    if fallback:
        try:
            items, next_token = _invidious_comments(video_id)
        except WatchError as exc:
            logger.warning(
                f"Invidious comments failed ({exc.detail[:60]}), trying yt-dlp"
            )
            items, next_token = _yt_dlp_comments(video_id)

    _cache_put(cache_key, (items, next_token), _TTL_COMMENTS)
    logger.info(f"Comments for {video_id}: {len(items)} items")
    return items, next_token
