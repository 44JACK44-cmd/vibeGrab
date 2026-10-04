import re
import subprocess
import threading
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, Header
from fastapi.responses import JSONResponse, StreamingResponse
from app.core.config import settings
from app.schemas.explore import (
    CommentsResponse,
    ExploreSearchResponse,
    PlayUrlResponse,
    RelatedResponse,
    StreamUrlResponse,
)
from app.services.anubis_client import ANTUBIS_UA, cookie_header, open_stream
from app.services.explore_service import search_videos
from app.services.youtube_watch_service import (
    WatchError,
    get_comments,
    get_play_url,
    get_relay_sources,
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
    allowed = host == "googlevideo.com" or host.endswith(".googlevideo.com")
    allowed = allowed or host.endswith(".f5.si")
    if parts.scheme != "https" or not allowed:
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Host not allowed for relay"},
        )

    req_headers = {"User-Agent": ANTUBIS_UA}
    if range_header:
        req_headers["Range"] = range_header

    try:
        upstream = open_stream(target, req_headers, timeout=30)
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


@router.get("/relay")
def relay(v: str):
    """Merge adaptive video+audio with ffmpeg and stream progressive mp4.

    Covers videos that have no muxed format. The phone only talks to us.
    """
    invalid = _validate_video_id(v)
    if invalid:
        return invalid
    try:
        sources = get_relay_sources(v)
    except WatchError as e:
        return JSONResponse(
            status_code=e.status,
            content={"success": False, "detail": e.detail},
        )
    except Exception as e:  # noqa: BLE001
        logger.error(f"Relay sources failed for {v}: {e}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": "relay unavailable"},
        )

    ua = ANTUBIS_UA
    try:
        ck = cookie_header(sources["video"])
    except Exception as e:  # noqa: BLE001
        logger.error(f"Anubis warmup failed: {e}")
        ck = None
    hdr_args = []
    if ck:
        hdr = f"Cookie: {ck}\r\nReferer: https://invidious.f5.si/\r\n"
        hdr_args = ["-headers", hdr]

    proc = subprocess.Popen(
        [
            settings.FFMPEG_PATH,
            "-hide_banner",
            "-loglevel", "error",
            "-user_agent", ua,
            *hdr_args,
            "-i", sources["video"],
            "-user_agent", ua,
            *hdr_args,
            "-i", sources["audio"],
            "-c", "copy",
            "-f", "mp4",
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "pipe:1",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    stderr_buf: list[bytes] = []

    def _drain_stderr():
        try:
            while True:
                data = proc.stderr.read(4096)
                if not data:
                    break
                if sum(len(c) for c in stderr_buf) < 8192:
                    stderr_buf.append(data)
        except Exception:
            pass

    threading.Thread(target=_drain_stderr, daemon=True).start()

    # Kill ffmpeg if it never produces output (network stall from our side).
    stall_killer = threading.Timer(60.0, proc.kill)
    stall_killer.start()
    first = proc.stdout.read(65536)
    stall_killer.cancel()
    if not first:
        proc.wait(timeout=30)
        tail = b"".join(stderr_buf).decode(errors="replace").strip()[-300:]
        logger.error(f"Relay ffmpeg failed for {v}: {tail}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": f"merge failed: {tail or 'unknown'}"},
        )

    def _gen():
        try:
            yield first
            while True:
                chunk = proc.stdout.read(65536)
                if not chunk:
                    break
                yield chunk
        finally:
            if proc.poll() is None:
                proc.kill()
            try:
                proc.wait(timeout=5)
            except Exception:
                pass

    return StreamingResponse(_gen(), media_type="video/mp4")


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
