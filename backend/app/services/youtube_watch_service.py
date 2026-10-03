import json
import re
import threading
import time

from app.core.logging import logger

_UA_COOKIES = {
    "Cookie": "CONSENT=YES+cb.20210328-17-p0.en+FX+000; SOCS=CAI",
    "Accept-Language": "en-US,en;q=0.9",
}
# Static innertube config: the watch HTML page gets HTTP 429 from datacenter
# IPs (Render), but the /youtubei/v1/next API works with the public web key.
_STATIC_CONFIG = {
    "api_key": "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8",
    "visitor": "",
    "context": {
        "client": {
            "clientName": "WEB",
            "clientVersion": "2.20261001.00.00",
            "hl": "en",
            "gl": "US",
        }
    },
}

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

    url = (
        "https://www.youtube.com/youtubei/v1/next"
        f"?key={bundle['api_key']}&prettyPrint=false"
    )
    headers = {
        "Content-Type": "application/json",
        "Origin": "https://www.youtube.com",
        "Referer": bundle["watch_url"],
        "X-Youtube-Client-Name": "1",
        "X-Youtube-Client-Version": bundle["context"]
        .get("client", {})
        .get("clientVersion", ""),
        "X-Goog-Visitor-Id": bundle.get("visitor") or "",
        **_UA_COOKIES,
    }
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
        raise WatchError(502, f"YouTube API HTTP {resp.status_code}")
    return resp.json()


def get_related(video_id: str) -> list[dict]:
    cache_key = f"related:{video_id}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached
    bundle = _bundle(video_id)
    payload = _post_next(bundle, {"context": bundle["context"], "videoId": video_id})
    items = parse_related(payload, exclude_id=video_id)
    _cache_put(cache_key, items, _TTL_RELATED)
    logger.info(f"Related for {video_id}: {len(items)} items")
    return items


def get_comments(video_id: str, token: str | None = None) -> tuple[list[dict], str | None]:
    cache_key = f"comments:{video_id}:{token or ''}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    bundle = _bundle(video_id)
    if token:
        next_payload = _post_next(
            bundle, {"context": bundle["context"], "continuation": token}
        )
        items, next_token = parse_comments(next_payload)
    else:
        first = _post_next(
            bundle, {"context": bundle["context"], "videoId": video_id}
        )
        comment_token = extract_comment_token(first)
        if not comment_token:
            _cache_put(cache_key, ([], None), _TTL_COMMENTS)
            return [], None
        next_payload = _post_next(
            bundle, {"context": bundle["context"], "continuation": comment_token}
        )
        items, next_token = parse_comments(next_payload)

    _cache_put(cache_key, (items, next_token), _TTL_COMMENTS)
    logger.info(f"Comments for {video_id}: {len(items)} items")
    return items, next_token
