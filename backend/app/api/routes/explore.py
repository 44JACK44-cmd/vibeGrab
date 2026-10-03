import re
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, Header
from fastapi.responses import JSONResponse, StreamingResponse
from app.schemas.explore import (
    CommentsResponse,
    ExploreSearchResponse,
    PlayUrlResponse,
    RelatedResponse,
    StreamUrlResponse,
)
from app.services.explore_service import search_videos
from app.services.youtube_watch_service import (
    WatchError,
    get_comments,
    get_play_url,
    get_related,
    get_stream_urls,
)
from app.core.logging import logger

router = APIRouter(prefix="/api/explore")

_VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")


@router.get("/proxy")
def proxy(u: str, range_header: str | None = Header(None, alias="Range")):
    """Byte relay for googlevideo streams.

    Some mobile networks block googlevideo directly; the phone downloads
    through us instead. Range is forwarded so seeking keeps working.
    """
    target = urllib.parse.unquote(u)
    parts = urllib.parse.urlsplit(target)
    host = (parts.hostname or "").lower()
    if parts.scheme != "https" or not (
        host == "googlevideo.com" or host.endswith(".googlevideo.com")
    ):
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Only googlevideo streams allowed"},
        )

    req_headers = {"User-Agent": "Mozilla/5.0 (Linux; Android 14) Chrome/140.0.0.0"}
    if range_header:
        req_headers["Range"] = range_header

    try:
        upstream = urllib.request.urlopen(
            urllib.request.Request(target, headers=req_headers), timeout=30
        )
    except urllib.error.HTTPError as e:
        return JSONResponse(
            status_code=e.code,
            content={"success": False, "detail": f"upstream {e.code}"},
        )
    except Exception as e:  # noqa: BLE001
        logger.error(f"Proxy upstream failed: {e}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": "upstream unavailable"},
        )

    def _gen():
        try:
            while True:
                chunk = upstream.read(65536)
                if not chunk:
                    break
                yield chunk
        finally:
            upstream.close()

    out_headers = {}
    for h in ("Content-Length", "Content-Range", "Accept-Ranges"):
        v = upstream.headers.get(h)
        if v:
            out_headers[h] = v

    return StreamingResponse(
        _gen(),
        status_code=upstream.status,
        media_type=upstream.headers.get("Content-Type", "application/octet-stream"),
        headers=out_headers,
    )


@router.get("/search")
def search(q: str, limit: int = 10):
    if not q or not q.strip():
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Search query is required"},
        )

    limit = max(1, min(limit, 20))

    try:
        results = search_videos(q.strip(), limit=limit)
        return ExploreSearchResponse(query=q.strip(), results=results)
    except Exception as e:
        logger.error(f"Search failed: {e}")
        return JSONResponse(
            status_code=500,
            content={"success": False, "detail": f"Search failed: {str(e)}"},
        )


def _validate_video_id(v: str) -> JSONResponse | None:
    if not v or not _VIDEO_ID_RE.fullmatch(v):
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Invalid video id"},
        )
    return None


@router.get("/related")
def related(v: str):
    invalid = _validate_video_id(v)
    if invalid:
        return invalid
    try:
        items = get_related(v)
        return RelatedResponse(items=items)
    except WatchError as e:
        return JSONResponse(
            status_code=e.status,
            content={"success": False, "detail": e.detail},
        )
    except Exception as e:
        logger.error(f"Related failed for {v}: {e}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": "Related videos unavailable"},
        )


@router.get("/comments")
def comments(v: str, token: str | None = None):
    invalid = _validate_video_id(v)
    if invalid:
        return invalid
    try:
        items, next_token = get_comments(v, token=token)
        return CommentsResponse(items=items, next_token=next_token)
    except WatchError as e:
        return JSONResponse(
            status_code=e.status,
            content={"success": False, "detail": e.detail},
        )
    except Exception as e:
        logger.error(f"Comments failed for {v}: {e}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": "Comments unavailable"},
        )


@router.get("/stream-url")
def stream_url(v: str):
    invalid = _validate_video_id(v)
    if invalid:
        return invalid
    try:
        return StreamUrlResponse(**get_stream_urls(v))
    except WatchError as e:
        return JSONResponse(
            status_code=e.status,
            content={"success": False, "detail": e.detail},
        )
    except Exception as e:
        logger.error(f"Stream url failed for {v}: {e}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": "Stream urls unavailable"},
        )


@router.get("/play-url")
def play_url(v: str):
    invalid = _validate_video_id(v)
    if invalid:
        return invalid
    try:
        return PlayUrlResponse(**get_play_url(v))
    except WatchError as e:
        return JSONResponse(
            status_code=e.status,
            content={"success": False, "detail": e.detail},
        )
    except Exception as e:
        logger.error(f"Play url failed for {v}: {e}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": "Play url unavailable"},
        )
