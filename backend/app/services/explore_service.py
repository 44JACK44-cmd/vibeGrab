import subprocess
import json
import random
import re
import threading
import time
from datetime import datetime, timezone
from urllib.parse import urlparse

from app.core.config import settings
from app.core.logging import logger
from app.schemas.explore import ExploreVideo

# Curated seeds used only when the real trending feed is unreachable.
# Every entry is executed as a real yt-dlp search, never as fixed data.
_FALLBACK_TRENDING_QUERIES = [
    "trending videos today",
    "popular music this week",
    "viral videos",
    "new music releases",
    "trending news",
]

_HOST_PROVIDERS = {
    "youtube.com": "youtube",
    "youtu.be": "youtube",
    "m.youtube.com": "youtube",
    "tiktok.com": "tiktok",
    "vm.tiktok.com": "tiktok",
    "instagram.com": "instagram",
    "facebook.com": "facebook",
    "twitter.com": "twitter",
    "x.com": "twitter",
    "vimeo.com": "vimeo",
    "dailymotion.com": "dailymotion",
    "soundcloud.com": "soundcloud",
    "twitch.tv": "twitch",
    "reddit.com": "reddit",
    "pinterest.com": "pinterest",
    "ted.com": "ted",
    "9gag.com": "9gag",
    "bilibili.com": "bilibili",
    "kwai.com": "kwai",
    "kuaishou.com": "kuaishou",
}


def search_videos(
    query: str,
    limit: int = 10,
    page: int = 1,
    sort: str = "relevance",
    when: str = "any",
) -> list[ExploreVideo]:
    """Real YouTube search with true pagination.

    Primary source is the innertube search API (one request gives title,
    channel, views, publish date and a continuation token for the next
    page). When YouTube blocks the datacenter IP, falls back to a yt-dlp
    search which paginates by slicing the first N*limit results.
    """
    limit = max(1, min(int(limit), 20))
    page = max(1, int(page))

    try:
        items = _innertube_search(query, limit=limit, page=page, sort=sort, when=when)
        if items or page > 1:
            return items
        logger.info("innertube search empty, falling back to yt-dlp")
    except Exception as e:  # noqa: BLE001
        logger.warning(f"innertube search failed ({e}), falling back to yt-dlp")

    return _ytdlp_search(query, limit=limit, page=page)


def _ytdlp_search(query: str, limit: int = 10, page: int = 1) -> list[ExploreVideo]:
    """yt-dlp backed search: requests the first N*limit results and slices
    the window [(N-1)*limit+1 .. N*limit] so page 2 never repeats page 1.
    """
    limit = max(1, min(int(limit), 20))
    page = max(1, int(page))
    start = (page - 1) * limit
    end = page * limit

    cache_key = f"{query.strip().lower()}|{page}|{limit}"
    cached = _search_cache_get(cache_key)
    if cached is not None:
        return cached

    cmd = [
        settings.YT_DLP_PATH,
        "--dump-json",
        "--flat-playlist",
        "--no-warnings",
        "--playlist-items",
        f"1-{end}",
        f"ytsearch{end}:{query}",
    ]

    logger.info(f"Searching YouTube: '{query}' (page={page}, limit={limit})")

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=40,
    )

    if result.returncode != 0:
        raise Exception(f"yt-dlp search error: {result.stderr.strip()}")

    all_videos = []
    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        try:
            video = _parse_result(json.loads(line))
            if video is not None:
                all_videos.append(video)
        except json.JSONDecodeError:
            continue

    videos = all_videos[start:end]
    _search_cache_put(cache_key, videos)
    return videos


_SEARCH_CACHE_TTL = 300
_search_cache: dict[str, tuple[float, list[ExploreVideo]]] = {}


def _search_cache_get(key: str) -> list[ExploreVideo] | None:
    hit = _search_cache.get(key)
    if hit is None:
        return None
    ts, videos = hit
    if time.time() - ts > _SEARCH_CACHE_TTL:
        _search_cache.pop(key, None)
        return None
    return list(videos)


def _search_cache_put(key: str, videos: list[ExploreVideo]) -> None:
    if len(_search_cache) > 120:
        _search_cache.clear()
    _search_cache[key] = (time.time(), list(videos))


# --- innertube search (primary source) --------------------------------
# One request returns title, channel, views, publish date and a
# continuation token, so pagination is real and cheap. YouTube may block
# datacenter IPs (Render); callers fall back to yt-dlp when that happens.

_INNERTUBE_TTL = 600
_SORT_PARAMS = {"relevance": None, "date": "CAI", "views": "CAM"}
_WHEN_PARAMS = {"any": None, "hour": "EgIIAQ==", "today": "EgIIAg==", "week": "EgIIBQ=="}
_SKIP_KEYS = {"header", "topbar", "sidebar", "playerOverlays", "adSlotRenderer"}

_search_state: dict[str, dict] = {}
_search_lock = threading.Lock()


def _post_search(payload: dict) -> dict:
    from curl_cffi import requests as cffi_requests

    from app.services.youtube_watch_service import _STATIC_CONFIG, _UA_COOKIES

    url = "https://www.youtube.com/youtubei/v1/search?prettyPrint=false"
    client_version = _STATIC_CONFIG["context"]["client"]["clientVersion"]
    headers = {
        "Content-Type": "application/json",
        "Origin": "https://www.youtube.com",
        "X-Youtube-Client-Name": "1",
        "X-Youtube-Client-Version": client_version,
        **_UA_COOKIES,
    }
    visitor = _STATIC_CONFIG.get("visitor") or ""
    if visitor:
        headers["X-Goog-Visitor-Id"] = visitor
    resp = cffi_requests.post(
        url,
        json=payload,
        headers=headers,
        impersonate="chrome",
        timeout=20,
    )
    if resp.status_code >= 400:
        raise RuntimeError(f"innertube search HTTP {resp.status_code}")
    return resp.json()


def _walk_search(node, items: list[ExploreVideo], tokens: list[str]) -> None:
    if isinstance(node, dict):
        if "videoRenderer" in node:
            item = _video_renderer_item(node["videoRenderer"])
            if item is not None:
                items.append(item)
        elif "lockupViewModel" in node:
            item = _lockup_to_item(node["lockupViewModel"])
            if item is not None:
                items.append(item)
        if "continuationItemRenderer" in node:
            endpoint = (
                node["continuationItemRenderer"]
                .get("continuationEndpoint", {})
                .get("continuationCommand", {})
                .get("token")
            )
            if endpoint:
                tokens.append(endpoint)
        for key, value in node.items():
            if key in _SKIP_KEYS:
                continue
            _walk_search(value, items, tokens)
    elif isinstance(node, list):
        for value in node:
            _walk_search(value, items, tokens)


def _parse_search_response(data: dict) -> tuple[list[ExploreVideo], str | None]:
    items: list[ExploreVideo] = []
    tokens: list[str] = []
    _walk_search(data, items, tokens)
    return items, (tokens[0] if tokens else None)


def _video_renderer_item(vr: dict) -> ExploreVideo | None:
    video_id = vr.get("videoId")
    if not video_id:
        return None
    title = _runs_text(vr.get("title"))
    if not title:
        return None
    channel = (
        _runs_text(vr.get("ownerText"))
        or _runs_text(vr.get("longBylineText"))
        or _runs_text(vr.get("shortBylineText"))
    )
    channel_id = None
    owner_runs = (vr.get("ownerText") or {}).get("runs") or []
    if owner_runs:
        browse = (owner_runs[0].get("navigationEndpoint") or {}).get("browseEndpoint") or {}
        channel_id = browse.get("browseId")
    views_text = _runs_text(vr.get("viewCountText")) or _runs_text(
        vr.get("shortViewCountText")
    )
    age = _runs_text(vr.get("publishedTimeText"))
    duration_string = _runs_text(vr.get("lengthText"))
    thumbnails = (vr.get("thumbnail") or {}).get("thumbnails") or []
    thumbnail = None
    for t in thumbnails:
        if (t.get("height") or 0) >= 360:
            thumbnail = t.get("url")
    if thumbnail is None and thumbnails:
        thumbnail = thumbnails[-1].get("url")
    if thumbnail is None:
        thumbnail = f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"

    return ExploreVideo(
        id=str(video_id),
        title=title,
        url=f"https://www.youtube.com/watch?v={video_id}",
        thumbnail=thumbnail,
        channel=channel,
        channel_id=channel_id,
        duration=_parse_hms(duration_string),
        duration_string=duration_string,
        view_count=_parse_count(views_text),
        views_label=None,
        age=age,
        provider="youtube",
    )


def _lockup_to_item(lv: dict) -> ExploreVideo | None:
    try:
        from app.services.youtube_watch_service import _lockup_item

        raw = _lockup_item(lv, None)
    except Exception:  # noqa: BLE001
        return None
    if not raw or not raw.get("id"):
        return None
    video_id = raw["id"]
    duration_string = raw.get("duration")
    return ExploreVideo(
        id=video_id,
        title=raw.get("title") or "",
        url=f"https://www.youtube.com/watch?v={video_id}",
        thumbnail=raw.get("thumbnail"),
        channel=raw.get("channel"),
        duration=_parse_hms(duration_string),
        duration_string=duration_string,
        view_count=_parse_count(raw.get("views")),
        views_label=None,
        age=raw.get("age"),
        provider="youtube",
    )


def _runs_text(node) -> str | None:
    if not node or not isinstance(node, dict):
        return None
    if "simpleText" in node:
        return node["simpleText"]
    runs = node.get("runs")
    if isinstance(runs, list):
        text = "".join(r.get("text", "") for r in runs if isinstance(r, dict))
        return text or None
    return None


def _parse_hms(label: str | None) -> int | None:
    if not label:
        return None
    parts = label.strip().split(":")
    if not parts or len(parts) > 3:
        return None
    try:
        nums = [int(p) for p in parts]
    except ValueError:
        return None
    total = 0
    for n in nums:
        total = total * 60 + n
    return total or None


def _parse_count(text: str | None) -> int | None:
    if not text:
        return None
    digits = re.sub(r"[^\d]", "", text)
    return int(digits) if digits else None


def _innertube_search(
    query: str, limit: int, page: int, sort: str, when: str
) -> list[ExploreVideo]:
    params = _WHEN_PARAMS.get(when) or _SORT_PARAMS.get(sort)
    key = f"{query.strip().lower()}|{params or '-'}"

    with _search_lock:
        state = _search_state.get(key)
        now = time.time()
        if state is None or now - state["at"] > _INNERTUBE_TTL:
            state = {
                "query": query.strip(),
                "params": params,
                "items": [],
                "seen": set(),
                "next_token": None,
                "exhausted": False,
                "at": now,
            }
            _search_state[key] = state
            if len(_search_state) > 40:
                for old in list(_search_state)[:-20]:
                    _search_state.pop(old, None)

    need = page * limit
    for _ in range(8):
        if state["exhausted"] or len(state["items"]) >= need:
            break
        is_first = not state["items"] and state["next_token"] is None
        if not is_first and state["next_token"] is None:
            state["exhausted"] = True
            break
        if is_first:
            payload = {"context": _search_context(), "query": state["query"]}
            if params:
                payload["params"] = params
        else:
            payload = {
                "context": _search_context(),
                "continuation": state["next_token"],
            }
        try:
            data = _post_search(payload)
        except Exception:
            try:
                data = _post_search(payload)  # one retry: transient resets happen
            except Exception:
                if state["items"]:
                    # Return the pages we already have instead of mixing a
                    # second source (which would duplicate results).
                    break
                state["exhausted"] = True
                raise
        items, token = _parse_search_response(data)
        for item in items:
            if item.id in state["seen"]:
                continue
            state["seen"].add(item.id)
            state["items"].append(item)
        state["next_token"] = token
        state["at"] = time.time()
        if token is None or not items:
            state["exhausted"] = True

    start = (page - 1) * limit
    return list(state["items"][start : start + limit])


def _search_context() -> dict:
    from app.services.youtube_watch_service import _STATIC_CONFIG

    return _STATIC_CONFIG["context"]


_trending_cache: tuple[float, list[ExploreVideo]] | None = None
_TRENDING_TTL = 600


def get_trending(limit: int = 20) -> tuple[list[ExploreVideo], str]:
    """Real "most viewed" content built from live searches.

    YouTube removed the /feed/trending tab (it redirects to the home page),
    so we rank real search results by view count across rotating seed
    queries: same idea as trending, always current, never hardcoded.
    """
    global _trending_cache
    limit = max(1, min(int(limit), 30))

    if _trending_cache and time.time() - _trending_cache[0] < _TRENDING_TTL:
        return list(_trending_cache[1][:limit]), "search"

    queries = list(_FALLBACK_TRENDING_QUERIES)
    random.shuffle(queries)

    out: list[ExploreVideo] = []
    seen: set[str] = set()
    for query in queries:
        if len(out) >= limit:
            break
        try:
            for video in search_videos(query, limit=10, page=1, sort="views"):
                if video.id in seen:
                    continue
                seen.add(video.id)
                out.append(video)
                if len(out) >= limit:
                    break
        except Exception as e:  # noqa: BLE001
            logger.warning(f"Trending seed '{query}' failed: {e}")

    if out:
        _trending_cache = (time.time(), list(out))
    return out[:limit], "search"


def get_link_metadata(url: str) -> dict:
    """Resolves a pasted link to metadata for any yt-dlp supported provider.

    Returns provider, playability and an ExploreVideo. Playback inside the
    app is only offered for sources the MediaSourceResolver can resolve.
    """
    url = (url or "").strip()
    if not url:
        raise ValueError("url is required")
    if not url.startswith(("http://", "https://")):
        url = "https://" + url

    provider = _provider_for(url)

    cmd = [
        settings.YT_DLP_PATH,
        "--dump-json",
        "--skip-download",
        "--no-playlist",
        "--no-warnings",
        url,
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=45)
    if result.returncode != 0:
        err = (result.stderr or "").strip().split("\n")[-1][:200]
        raise Exception(f"metadata failed: {err}")

    lines = [l for l in result.stdout.strip().split("\n") if l.strip()]
    if not lines:
        raise Exception("metadata failed: empty response")
    data = json.loads(lines[0])

    provider = (data.get("extractor_key") or data.get("extractor") or provider or "unknown")
    provider = str(provider).strip().lower()
    if "youtube" in provider:
        provider = "youtube"

    video = _parse_result(data)
    if video is None:
        raise Exception("metadata failed: no id")

    playable = provider == "youtube"
    reason = None
    if not playable:
        reason = "provider_not_playable"

    return {
        "provider": provider,
        "playable": playable,
        "downloadable": True,
        "reason": reason,
        "video": video,
    }


def _provider_for(url: str) -> str:
    try:
        host = (urlparse(url).hostname or "").lower()
    except Exception:  # noqa: BLE001
        return "unknown"
    for suffix, name in _HOST_PROVIDERS.items():
        if host == suffix or host.endswith("." + suffix):
            return name
    return "unknown"


def _parse_result(data: dict) -> ExploreVideo | None:
    video_id = data.get("id")
    if not video_id:
        return None

    url = _resolve_url(data, str(video_id))

    extractor = str(
        data.get("extractor_key") or data.get("ie_key") or data.get("extractor") or ""
    ).lower()
    provider = "youtube"
    if "youtube" not in extractor:
        provider = _provider_for(url)
        if provider == "unknown" and extractor:
            provider = extractor.replace("extractor", "").strip() or "unknown"
        if provider == "unknown" and _looks_youtube_id(str(video_id)):
            provider = "youtube"

    title = data.get("title") or "Untitled"
    thumbnail = _best_thumbnail(data)
    channel = data.get("channel") or data.get("uploader")
    duration = data.get("duration")
    duration_string = data.get("duration_string") or _duration_string(duration)
    view_count = data.get("view_count")
    timestamp = data.get("timestamp") or data.get("release_timestamp")
    upload_date = data.get("upload_date")

    return ExploreVideo(
        id=str(video_id),
        title=title,
        url=url,
        thumbnail=thumbnail,
        channel=channel,
        channel_id=data.get("channel_id"),
        duration=int(duration) if duration else None,
        duration_string=duration_string,
        view_count=int(view_count) if view_count else None,
        views_label=_views_label(view_count),
        age=_age_label(timestamp, upload_date),
        provider=provider,
    )


def _resolve_url(data: dict, video_id: str) -> str:
    for candidate in (data.get("webpage_url"), data.get("original_url")):
        if candidate and str(candidate).startswith("http"):
            return str(candidate)
    raw = str(data.get("url") or "")
    if raw.startswith("http"):
        return raw
    if _looks_youtube_id(video_id):
        return f"https://www.youtube.com/watch?v={video_id}"
    if raw:
        return raw
    return f"https://www.youtube.com/watch?v={video_id}"


def _looks_youtube_id(video_id: str) -> bool:
    return isinstance(video_id, str) and len(video_id) == 11


def _duration_string(duration) -> str | None:
    if not duration:
        return None
    try:
        total = int(duration)
    except (TypeError, ValueError):
        return None
    h, rem = divmod(total, 3600)
    m, s = divmod(rem, 60)
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def _views_label(view_count) -> str | None:
    if not view_count:
        return None
    try:
        n = int(view_count)
    except (TypeError, ValueError):
        return None
    if n >= 1_000_000_000:
        return f"{n / 1_000_000_000:.1f}B views"
    if n >= 1_000_000:
        return f"{n / 1_000_000:.1f}M views"
    if n >= 1_000:
        return f"{n / 1_000:.0f}K views"
    return f"{n} views"


def _age_label(timestamp, upload_date) -> str | None:
    dt: datetime | None = None
    if timestamp:
        try:
            dt = datetime.fromtimestamp(int(timestamp), tz=timezone.utc)
        except (TypeError, ValueError, OSError):
            dt = None
    if dt is None and upload_date:
        try:
            dt = datetime.strptime(str(upload_date), "%Y%m%d").replace(tzinfo=timezone.utc)
        except ValueError:
            dt = None
    if dt is None:
        return None

    seconds = max(0, int((datetime.now(timezone.utc) - dt).total_seconds()))
    if seconds < 60:
        return "just now"
    if seconds < 3600:
        m = seconds // 60
        return f"{m} minute{'s' if m != 1 else ''} ago"
    if seconds < 86400:
        h = seconds // 3600
        return f"{h} hour{'s' if h != 1 else ''} ago"
    if seconds < 86400 * 7:
        d = seconds // 86400
        return f"{d} day{'s' if d != 1 else ''} ago"
    if seconds < 86400 * 30:
        w = seconds // (86400 * 7)
        return f"{w} week{'s' if w != 1 else ''} ago"
    if seconds < 86400 * 365:
        mo = seconds // (86400 * 30)
        return f"{mo} month{'s' if mo != 1 else ''} ago"
    y = seconds // (86400 * 365)
    return f"{y} year{'s' if y != 1 else ''} ago"


def _best_thumbnail(data: dict) -> str | None:
    thumbnails = data.get("thumbnails", [])
    if thumbnails:
        for t in thumbnails:
            if (t.get("height") or 0) >= 360:
                return t.get("url")
        return thumbnails[-1].get("url")
    return data.get("thumbnail")
