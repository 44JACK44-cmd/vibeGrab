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


class ExploreError(Exception):
    """Raised when an explore/search operation cannot be completed.

    Subclasses ``Exception`` so existing ``except Exception`` callers keep
    working unchanged while giving the module a specific error type.
    """


# http(s) scheme prefixes reused across the module (kept as constants so the
# literal is not duplicated and SonarCloud stays happy).
_HTTP_PREFIX = "http://"
_HTTPS_PREFIX = "https://"
_HTTP_SCHEMES = (_HTTP_PREFIX, _HTTPS_PREFIX)

# Search terms are user supplied and end up as a yt-dlp argument; reject
# control characters and clamp the length before use (Sonar S6350).
_MAX_SEARCH_TERM_LENGTH = 200
_CONTROL_CHARS_RE = re.compile(r"[\x00-\x1f\x7f]")

# Non-cryptographic RNG: SystemRandom only keeps the rotating trending seeds
# from always being tried in the same order, so os.urandom entropy is plenty.
_RANDOM = random.SystemRandom()

# Curated seeds per UI language, used only when the real trending feed is
# unreachable. Every entry is executed as a real search, never fixed data.
_TRENDING_QUERIES: dict[str, list[str]] = {
    "en": [
        "trending videos today",
        "popular music this week",
        "viral videos",
        "new music releases",
        "trending news",
    ],
    "es": [
        "videos en tendencia hoy",
        "éxitos musicales de la semana",
        "videos virales",
        "nuevos estrenos de música",
        "noticias de tendencia",
    ],
}
_FALLBACK_TRENDING_QUERIES = _TRENDING_QUERIES["en"]

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


def _norm_locale(lang: str | None, gl: str | None) -> tuple[str, str]:
    """Sanitize the feed locale pair (innertube hl/gl) to safe values."""
    lang = (lang or "en").strip().lower()
    if not re.fullmatch(r"[a-z]{2,3}", lang):
        lang = "en"
    gl = (gl or "").strip().upper()
    if not re.fullmatch(r"[A-Z]{2}", gl):
        gl = "ES" if lang == "es" else "US"
    return lang, gl


def search_videos(
    query: str,
    limit: int = 10,
    page: int = 1,
    sort: str = "relevance",
    when: str = "any",
    lang: str = "en",
    gl: str = "US",
) -> list[ExploreVideo]:
    """Real YouTube search with true pagination.

    Primary source is the innertube search API (one request gives title,
    channel, views, publish date and a continuation token for the next
    page). When YouTube blocks the datacenter IP, falls back to a yt-dlp
    search which paginates by slicing the first N*limit results.
    [lang]/[gl] drive the innertube client locale (hl/gl) so results match
    the user's region; the yt-dlp fallback just uses the (already
    localized) query text.
    """
    limit = max(1, min(int(limit), 20))
    page = max(1, int(page))
    lang, gl = _norm_locale(lang, gl)

    try:
        items = _innertube_search(
            query, limit=limit, page=page, sort=sort, when=when, lang=lang, gl=gl
        )
        if items or page > 1:
            return items
        logger.info("innertube search empty, falling back to yt-dlp")
    except Exception as e:  # noqa: BLE001
        logger.warning(f"innertube search failed ({e}), falling back to yt-dlp")

    return _ytdlp_search(query, limit=limit, page=page)


def _clean_search_term(query: str) -> str:
    """Validate a user search term before it reaches yt-dlp.

    Rejects control characters and clamps the length so a crafted term can
    never inject extra arguments or escape the ``ytsearch`` value.
    """
    term = (query or "").strip()
    if not term:
        raise ValueError("search term is required")
    if _CONTROL_CHARS_RE.search(term):
        raise ValueError("search term contains control characters")
    return term[:_MAX_SEARCH_TERM_LENGTH]


def _ytdlp_search(query: str, limit: int = 10, page: int = 1) -> list[ExploreVideo]:
    """yt-dlp backed search: requests the first N*limit results and slices
    the window [(N-1)*limit+1 .. N*limit] so page 2 never repeats page 1.
    """
    limit = max(1, min(int(limit), 20))
    page = max(1, int(page))
    start = (page - 1) * limit
    end = page * limit
    term = _clean_search_term(query)

    cache_key = f"{term.lower()}|{page}|{limit}"
    cached = _search_cache_get(cache_key)
    if cached is not None:
        return cached

    # Arguments are always passed as a list (never a command string); the
    # search term itself was validated above.
    cmd = [
        settings.YT_DLP_PATH,
        "--dump-json",
        "--flat-playlist",
        "--no-warnings",
        "--playlist-items",
        f"1-{end}",
        f"ytsearch{end}:{term}",
    ]

    logger.info(f"Searching YouTube: '{term}' (page={page}, limit={limit})")

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=40,
    )

    if result.returncode != 0:
        raise ExploreError(f"yt-dlp search error: {result.stderr.strip()}")

    all_videos = _parse_ytdlp_lines(result.stdout)
    videos = all_videos[start:end]
    _search_cache_put(cache_key, videos)
    return videos


def _parse_ytdlp_lines(stdout: str) -> list[ExploreVideo]:
    """Parse the newline-delimited JSON dump emitted by yt-dlp."""
    videos: list[ExploreVideo] = []
    for line in stdout.strip().split("\n"):
        if not line.strip():
            continue
        try:
            video = _parse_result(json.loads(line))
        except json.JSONDecodeError:
            continue
        if video is not None:
            videos.append(video)
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


def _post_search(payload: dict, lang: str = "en", gl: str = "US") -> dict:
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
        # Locale-specific negotiation so the feed matches hl/gl of the user.
        "Accept-Language": f"{lang}-{gl},{lang};q=0.8,en;q=0.5",
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


def _append_video_node(node: dict, items: list[ExploreVideo]) -> None:
    """Append the video held by a known renderer node, when present."""
    if "videoRenderer" in node:
        item = _video_renderer_item(node["videoRenderer"])
    elif "lockupViewModel" in node:
        item = _lockup_to_item(node["lockupViewModel"])
    else:
        return
    if item is not None:
        items.append(item)


def _collect_continuation_token(node: dict, tokens: list[str]) -> None:
    """Append the continuation token carried by a renderer node, when present."""
    endpoint = (
        node["continuationItemRenderer"]
        .get("continuationEndpoint", {})
        .get("continuationCommand", {})
        .get("token")
    )
    if endpoint:
        tokens.append(endpoint)


def _walk_search(node, items: list[ExploreVideo], tokens: list[str]) -> None:
    if isinstance(node, dict):
        if "videoRenderer" in node or "lockupViewModel" in node:
            _append_video_node(node, items)
        if "continuationItemRenderer" in node:
            _collect_continuation_token(node, tokens)
        for key, value in node.items():
            if key not in _SKIP_KEYS:
                _walk_search(value, items, tokens)
    elif isinstance(node, list):
        for value in node:
            _walk_search(value, items, tokens)


def _parse_search_response(data: dict) -> tuple[list[ExploreVideo], str | None]:
    items: list[ExploreVideo] = []
    tokens: list[str] = []
    _walk_search(data, items, tokens)
    return items, (tokens[0] if tokens else None)


def _renderer_channel_id(vr: dict) -> str | None:
    """Extract the channel browse id from a videoRenderer node."""
    owner_runs = (vr.get("ownerText") or {}).get("runs") or []
    if not owner_runs:
        return None
    browse = (owner_runs[0].get("navigationEndpoint") or {}).get("browseEndpoint") or {}
    return browse.get("browseId")


def _renderer_thumbnail(vr: dict, video_id: str) -> str:
    """Pick the best available thumbnail URL, falling back to YouTube's."""
    thumbnails = (vr.get("thumbnail") or {}).get("thumbnails") or []
    thumbnail = None
    for thumb in thumbnails:
        if (thumb.get("height") or 0) >= 360:
            thumbnail = thumb.get("url")
    if thumbnail is None and thumbnails:
        thumbnail = thumbnails[-1].get("url")
    if thumbnail is None:
        return f"https://i.ytimg.com/vi/{video_id}/hqdefault.jpg"
    return thumbnail


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
    views_text = _runs_text(vr.get("viewCountText")) or _runs_text(
        vr.get("shortViewCountText")
    )
    duration_string = _runs_text(vr.get("lengthText"))

    return ExploreVideo(
        id=str(video_id),
        title=title,
        url=f"https://www.youtube.com/watch?v={video_id}",
        thumbnail=_renderer_thumbnail(vr, video_id),
        channel=channel,
        channel_id=_renderer_channel_id(vr),
        duration=_parse_hms(duration_string),
        duration_string=duration_string,
        view_count=_parse_count(views_text),
        views_label=None,
        age=_runs_text(vr.get("publishedTimeText")),
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


def _trim_search_state() -> None:
    """Drop the oldest cached search states, keeping the dict bounded."""
    if len(_search_state) > 40:
        for old in list(_search_state)[:-20]:
            _search_state.pop(old, None)


def _get_search_state(key: str, query: str, params: str | None, now: float) -> dict:
    """Return the cached paging state for [key], creating it when stale."""
    with _search_lock:
        state = _search_state.get(key)
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
            _trim_search_state()
        return state


def _is_first_search_page(state: dict) -> bool:
    """True while no page has been fetched yet for this state."""
    return not state["items"] and state["next_token"] is None


def _build_search_payload(state: dict, params: str | None, lang: str, gl: str) -> dict:
    """Build the innertube payload for the first page or a continuation."""
    if _is_first_search_page(state):
        payload = {
            "context": _search_context(lang, gl),
            "query": state["query"],
        }
        if params:
            payload["params"] = params
        return payload
    return {
        "context": _search_context(lang, gl),
        "continuation": state["next_token"],
    }


def _fetch_search_page(payload: dict, lang: str, gl: str, state: dict) -> dict | None:
    """Fetch one innertube page with a single retry for transient resets.

    Returns ``None`` when we should stop because earlier pages were already
    collected; otherwise returns the parsed JSON response.
    """
    try:
        return _post_search(payload, lang, gl)
    except Exception:
        try:
            return _post_search(payload, lang, gl)
        except Exception:
            if state["items"]:
                # Return the pages we already have instead of mixing a
                # second source (which would duplicate results).
                return None
            state["exhausted"] = True
            raise


def _merge_search_page(state: dict, data: dict) -> None:
    """Append a page's new items and advance the continuation token."""
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


def _innertube_search(
    query: str,
    limit: int,
    page: int,
    sort: str,
    when: str,
    lang: str = "en",
    gl: str = "US",
) -> list[ExploreVideo]:
    params = _WHEN_PARAMS.get(when) or _SORT_PARAMS.get(sort)
    key = f"{query.strip().lower()}|{params or '-'}|{lang}|{gl}"
    state = _get_search_state(key, query, params, time.time())

    need = page * limit
    for _ in range(8):
        if state["exhausted"] or len(state["items"]) >= need:
            break
        if not _is_first_search_page(state) and state["next_token"] is None:
            state["exhausted"] = True
            break
        payload = _build_search_payload(state, params, lang, gl)
        data = _fetch_search_page(payload, lang, gl, state)
        if data is None:
            break
        _merge_search_page(state, data)

    start = (page - 1) * limit
    return list(state["items"][start : start + limit])


def _search_context(lang: str = "en", gl: str = "US") -> dict:
    from app.services.youtube_watch_service import _STATIC_CONFIG

    ctx = json.loads(json.dumps(_STATIC_CONFIG["context"]))
    client = ctx.setdefault("client", {})
    client["hl"] = lang
    client["gl"] = gl
    return ctx


_trending_cache: dict[tuple[str, str], tuple[float, list[ExploreVideo]]] = {}
_TRENDING_TTL = 600


def _collect_trending_seed(
    query: str,
    limit: int,
    lang: str,
    gl: str,
    out: list[ExploreVideo],
    seen: set[str],
) -> None:
    """Run one seed query and append its unseen videos to [out]."""
    try:
        for video in search_videos(
            query, limit=10, page=1, sort="views", lang=lang, gl=gl
        ):
            if video.id in seen:
                continue
            seen.add(video.id)
            out.append(video)
            if len(out) >= limit:
                break
    except Exception as e:  # noqa: BLE001
        logger.warning(f"Trending seed '{query}' failed: {e}")


def _collect_trending(
    queries: list[str], limit: int, lang: str, gl: str
) -> list[ExploreVideo]:
    """Run the rotating seed queries until [limit] unique videos are found."""
    out: list[ExploreVideo] = []
    seen: set[str] = set()
    for query in queries:
        if len(out) >= limit:
            break
        _collect_trending_seed(query, limit, lang, gl, out, seen)
    return out


def _cache_trending(lang: str, gl: str, out: list[ExploreVideo]) -> None:
    """Store a trending result and keep the per-locale cache bounded."""
    _trending_cache[(lang, gl)] = (time.time(), list(out))
    if len(_trending_cache) > 8:
        for old in sorted(_trending_cache, key=lambda k: _trending_cache[k][0])[
            : len(_trending_cache) - 8
        ]:
            _trending_cache.pop(old, None)


def get_trending(
    limit: int = 20, lang: str = "en", gl: str = "US"
) -> tuple[list[ExploreVideo], str]:
    """Real "most viewed" content built from live searches.

    YouTube removed the /feed/trending tab (it redirects to the home page),
    so we rank real search results by view count across rotating seed
    queries: same idea as trending, always current, never hardcoded.
    The cache is keyed per locale so es/es users get a Spanish feed and
    en/us users get an English one.
    """
    limit = max(1, min(int(limit), 30))
    lang, gl = _norm_locale(lang, gl)

    cached = _trending_cache.get((lang, gl))
    if cached and time.time() - cached[0] < _TRENDING_TTL:
        return list(cached[1][:limit]), "search"

    queries = list(_TRENDING_QUERIES.get(lang[:2], _TRENDING_QUERIES["en"]))
    _RANDOM.shuffle(queries)

    out = _collect_trending(queries, limit, lang, gl)
    if out:
        _cache_trending(lang, gl, out)
    return out[:limit], "search"


def _is_playable_format(fmt) -> bool:
    """True when extractor._normalize_format would keep this format.

    Direct http(s) media URL (HLS/DASH excluded — analyze rejects them)
    with at least one real stream. Same rule the download path uses.
    """
    if not isinstance(fmt, dict):
        return False
    url = str(fmt.get("url") or "")
    if not url.startswith(_HTTP_SCHEMES):
        return False
    protocol = str(fmt.get("protocol") or "")
    if "m3u8" in protocol or "m3u8" in url or "dash" in protocol:
        return False
    return (fmt.get("vcodec") or "none") != "none" or (
        fmt.get("acodec") or "none"
    ) != "none"


def get_link_metadata(url: str) -> dict:
    """Resolves a pasted link to metadata for any yt-dlp supported provider.

    Returns provider, playability and an ExploreVideo. Playback is offered
    for YouTube plus any provider whose formats expose a direct media URL —
    the app plays those through /api/analyze in its own player.
    """
    url = (url or "").strip()
    if not url:
        raise ValueError("url is required")
    if not url.startswith(_HTTP_SCHEMES):
        url = f"{_HTTPS_PREFIX}{url}"

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
        raise ExploreError(f"metadata failed: {err}")

    lines = [line for line in result.stdout.strip().split("\n") if line.strip()]
    if not lines:
        raise ExploreError("metadata failed: empty response")
    data = json.loads(lines[0])

    provider = (data.get("extractor_key") or data.get("extractor") or provider or "unknown")
    provider = str(provider).strip().lower()
    if "youtube" in provider:
        provider = "youtube"

    video = _parse_result(data)
    if video is None:
        raise ExploreError("metadata failed: no id")

    # Playable whenever we can hand the app a direct media URL: the
    # MediaEngine resolves it through /api/analyze and plays it in-app,
    # so TikTok/Instagram/Facebook links play in our own player too.
    # Criteria mirror extractor._normalize_format (no HLS/DASH-only
    # providers — analyze would reject those and playback would fail).
    formats = data.get("formats") or []
    has_direct_url = any(_is_playable_format(f) for f in formats)
    playable = provider == "youtube" or has_direct_url
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


def _provider_from_data(data: dict, url: str, video_id) -> str:
    """Resolve the provider slug from yt-dlp extractor metadata and URL."""
    extractor = str(
        data.get("extractor_key") or data.get("ie_key") or data.get("extractor") or ""
    ).lower()
    if "youtube" in extractor:
        return "youtube"
    provider = _provider_for(url)
    if provider == "unknown" and extractor:
        provider = extractor.replace("extractor", "").strip() or "unknown"
    if provider == "unknown" and _looks_youtube_id(str(video_id)):
        provider = "youtube"
    return provider


def _parse_result(data: dict) -> ExploreVideo | None:
    video_id = data.get("id")
    if not video_id:
        return None

    url = _resolve_url(data, str(video_id))

    duration = data.get("duration")
    duration_string = data.get("duration_string") or _duration_string(duration)
    view_count = data.get("view_count")
    timestamp = data.get("timestamp") or data.get("release_timestamp")
    upload_date = data.get("upload_date")

    return ExploreVideo(
        id=str(video_id),
        title=data.get("title") or "Untitled",
        url=url,
        thumbnail=_best_thumbnail(data),
        channel=data.get("channel") or data.get("uploader"),
        channel_id=data.get("channel_id"),
        duration=int(duration) if duration else None,
        duration_string=duration_string,
        view_count=int(view_count) if view_count else None,
        views_label=_views_label(view_count),
        age=_age_label(timestamp, upload_date),
        provider=_provider_from_data(data, url, video_id),
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


# Ordered (upper bound, seconds per unit, unit name) used to render an age.
_AGE_UNITS: tuple[tuple[int, int, str], ...] = (
    (3600, 60, "minute"),
    (86400, 3600, "hour"),
    (86400 * 7, 86400, "day"),
    (86400 * 30, 86400 * 7, "week"),
    (86400 * 365, 86400 * 30, "month"),
)
_SECONDS_PER_YEAR = 86400 * 365


def _parse_age_datetime(timestamp, upload_date) -> datetime | None:
    """Build a UTC datetime from a yt-dlp timestamp or upload date string."""
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
    return dt


def _format_age(seconds: int, unit_seconds: int, unit: str) -> str:
    value = seconds // unit_seconds
    return f"{value} {unit}{'s' if value != 1 else ''} ago"


def _age_label(timestamp, upload_date) -> str | None:
    dt = _parse_age_datetime(timestamp, upload_date)
    if dt is None:
        return None

    seconds = max(0, int((datetime.now(timezone.utc) - dt).total_seconds()))
    if seconds < 60:
        return "just now"
    for threshold, unit_seconds, unit in _AGE_UNITS:
        if seconds < threshold:
            return _format_age(seconds, unit_seconds, unit)
    return _format_age(seconds, _SECONDS_PER_YEAR, "year")


def _best_thumbnail(data: dict) -> str | None:
    thumbnails = data.get("thumbnails", [])
    if thumbnails:
        for t in thumbnails:
            if (t.get("height") or 0) >= 360:
                return t.get("url")
        return thumbnails[-1].get("url")
    return data.get("thumbnail")
