import re
import shutil
import subprocess
import threading
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from fastapi import APIRouter, BackgroundTasks, Query
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from app.schemas.analyze import AnalyzeRequest, AnalyzeResponse
from app.schemas.download import (
    DownloadRequest,
    DownloadCreateResponse,
    DownloadStatusResponse,
    CancelResponse,
    DownloadStatus,
)
from app.services.validation_service import extract_url, normalize_url, validate_url
from app.services.extractor_service import extract_media_info
from app.services.audio_service import AudioConversionError, convert_to_mp3
from app.services.download_service import (
    create_task, get_task, list_tasks, cancel_task, start_download, init_store,
)
from app.services import task_store
from app.services.library_service import get_disk_space
from app.core.logging import logger
from app.core.config import settings


@asynccontextmanager
async def lifespan(app):
    init_store()
    yield


router = APIRouter(prefix="/api", lifespan=lifespan)


def _check_tool(path: str) -> dict:
    """Check if a CLI tool is available."""
    try:
        shutil.which(path)
        return {"available": True, "path": path}
    except Exception:
        return {"available": False, "path": path, "error": "not found"}


@router.get("/health")
def health():
    return {"status": "ok", "service": "vibegrab"}


@router.get("/status")
def status():
    """Full system status: tool availability, disk space, task counts."""
    disk = get_disk_space()
    tasks = list_tasks()

    active = [t for t in tasks if t.status in (
        DownloadStatus.QUEUED,
        DownloadStatus.PREPARING,
        DownloadStatus.DOWNLOADING,
        DownloadStatus.PROCESSING,
    )]

    return {
        "status": "ok",
        "version": settings.VERSION,
        "tools": {
            "yt_dlp": _check_tool(settings.YT_DLP_PATH),
            "ffmpeg": _check_tool(settings.FFMPEG_PATH),
        },
        "disk": disk,
        "max_concurrent_downloads": settings.MAX_CONCURRENT_DOWNLOADS,
        "tasks": {
            "total": len(tasks),
            "active": len(active),
            "completed": sum(1 for t in tasks if t.status == DownloadStatus.COMPLETED),
            "failed": sum(1 for t in tasks if t.status == DownloadStatus.FAILED),
        },
    }


@router.post("/analyze")
def analyze(req: AnalyzeRequest):
    raw_url = extract_url(req.url)
    if not raw_url:
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "No valid URL found in input"},
        )

    url = normalize_url(raw_url)

    if not validate_url(url):
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Unsupported or invalid URL"},
        )

    try:
        media, formats = extract_media_info(url)
    except Exception as e:
        logger.error(f"Extraction failed for {url}: {e}")
        return JSONResponse(
            status_code=422,
            content={"success": False, "detail": f"Could not extract media info: {str(e)}"},
        )

    if not formats:
        return JSONResponse(
            status_code=422,
            content={"success": False, "detail": "No downloadable formats found"},
        )

    return AnalyzeResponse(success=True, media=media, formats=formats)


_MIME_BY_EXT = {
    "mp4": "video/mp4",
    "m4v": "video/x-m4v",
    "mov": "video/quicktime",
    "webm": "video/webm",
    "mkv": "video/x-matroska",
    "m4a": "audio/mp4",
    "mp3": "audio/mpeg",
    "aac": "audio/aac",
    "ogg": "audio/ogg",
    "opus": "audio/ogg",
    "wav": "audio/wav",
}


def _stderr_tail(buf: list[bytes], length: int = 400) -> str:
    return b"".join(buf).decode(errors="replace").strip()[-length:]


def _drain_stderr(proc: subprocess.Popen, buf: list[bytes]) -> None:
    """Keep reading yt-dlp stderr so its pipe never blocks."""
    try:
        while True:
            data = proc.stderr.read(4096)
            if not data:
                break
            if sum(len(c) for c in buf) < 8192:
                buf.append(data)
    except Exception:
        pass


def _stream_fetch(proc: subprocess.Popen, first: bytes, stderr_buf: list[bytes]):
    try:
        yield first
        while True:
            chunk = proc.stdout.read(65536)
            if not chunk:
                break
            yield chunk
        proc.wait(timeout=60)
        if proc.returncode != 0:
            tail = _stderr_tail(stderr_buf)
            logger.warning(f"Fetch stream ended with exit {proc.returncode}: {tail}")
    finally:
        if proc.poll() is None:
            try:
                proc.kill()
            except Exception:
                pass


def _validate_fetch_target(url: str) -> str | JSONResponse:
    """Return the normalized fetch URL or a 400 JSONResponse."""
    raw_url = extract_url(url)
    if not raw_url:
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "No valid URL found in input"},
        )
    target = normalize_url(raw_url)
    if not validate_url(target):
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Unsupported or invalid URL"},
        )
    return target


def _spawn_fetch(target: str, format_id: str) -> subprocess.Popen:
    return subprocess.Popen(
        [
            settings.YT_DLP_PATH,
            "-f", format_id,
            "-o", "-",
            "--no-warnings",
            "--no-playlist",
            "--socket-timeout", "30",
            target,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


@router.get("/fetch")
def fetch_media(
    url: str = Query(..., min_length=10, max_length=2048),
    format_id: str = Query(..., min_length=1, max_length=64),
    ext: str = Query("mp4", max_length=8),
):
    """Stream a single yt-dlp format to the client (server-side download relay)."""
    target = _validate_fetch_target(url)
    if isinstance(target, JSONResponse):
        return target
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+", format_id):
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Invalid format id"},
        )

    logger.info(f"Streaming fetch: {target} format={format_id}")

    proc = _spawn_fetch(target, format_id)

    stderr_buf: list[bytes] = []
    threading.Thread(
        target=_drain_stderr, args=(proc, stderr_buf), daemon=True
    ).start()

    first = proc.stdout.read(65536)
    if not first:
        proc.wait(timeout=30)
        tail = _stderr_tail(stderr_buf)
        logger.error(f"Fetch failed for {target}: {tail}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": f"Extractor failed: {tail or 'unknown error'}"},
        )

    mime = _MIME_BY_EXT.get(ext.lower(), "application/octet-stream")
    return StreamingResponse(_stream_fetch(proc, first, stderr_buf), media_type=mime)


@router.get("/convert/audio")
def convert_audio(
    background_tasks: BackgroundTasks,
    url: str = Query("", max_length=2048),
    format_id: str = Query("", max_length=64),
    direct: str = Query("", max_length=2048),
    title: str = Query("", max_length=200),
    artist: str = Query("", max_length=200),
    cover: str = Query("", max_length=2048),
):
    """Convert one audio track to a real MP3 with tags and cover.

    The phone cannot run ffmpeg (Android apps cannot execute a bundled binary
    and VibeGrab ships none), so this is the only place where "MP3" can be the
    real thing instead of a renamed m4a. The finished file is streamed back and
    the temporary directory is removed afterwards.
    """
    if not url and not direct:
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Missing source"},
        )
    if url:
        target = _validate_fetch_target(url)
        if isinstance(target, JSONResponse):
            return target
        url = target
    if format_id and not re.fullmatch(r"[A-Za-z0-9_.+-]+", format_id):
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Invalid format id"},
        )

    work = Path(settings.TEMP_DIR) / f"mp3-{uuid.uuid4().hex[:10]}"
    try:
        output = convert_to_mp3(
            work,
            url=url,
            format_id=format_id,
            direct_url=direct,
            title=title,
            artist=artist,
            cover_url=cover,
        )
    except AudioConversionError as exc:
        shutil.rmtree(work, ignore_errors=True)
        logger.error(f"Audio conversion failed ({url or direct[:80]}): {exc}")
        return JSONResponse(
            status_code=502,
            content={"success": False, "detail": f"Conversion failed: {exc}"},
        )

    background_tasks.add_task(shutil.rmtree, work, ignore_errors=True)
    filename = _safe_filename(title) + ".mp3"
    return FileResponse(
        output,
        media_type="audio/mpeg",
        filename=filename,
        headers={"X-VibeGrab-Format": "mp3"},
    )


def _safe_filename(title: str) -> str:
    """A conservative file name for the Content-Disposition header."""
    cleaned = re.sub(r'[\\/:*?"<>|\r\n\t]', "_", title).strip(" .")
    return cleaned[:80] or "audio"


@router.post("/downloads")
async def create_download(req: DownloadRequest, background_tasks: BackgroundTasks):
    raw_url = extract_url(req.url)
    if not raw_url:
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Invalid URL"},
        )

    url = normalize_url(raw_url)

    if not validate_url(url):
        return JSONResponse(
            status_code=400,
            content={"success": False, "detail": "Unsupported URL"},
        )

    disk = get_disk_space()
    if disk["exists"] and disk["free_bytes"] < settings.MIN_FREE_SPACE_MB * 1024 * 1024:
        return JSONResponse(
            status_code=507,
            content={
                "success": False,
                "detail": f"Insufficient disk space ({disk['free_formatted']} free, need at least {settings.MIN_FREE_SPACE_MB} MB)",
            },
        )

    task = create_task(
        url=url,
        format_id=req.format_id,
        title=req.title,
        has_video=req.has_video,
        has_audio=req.has_audio,
    )

    if req.thumbnail or req.source:
        task_store.update(task.id, thumbnail=req.thumbnail, source=req.source)

    background_tasks.add_task(start_download, task.id)

    task_updated = get_task(task.id)
    return DownloadCreateResponse(task_id=task.id, status=task_updated.status)


@router.get("/downloads/{task_id}")
def get_download_status(task_id: str):
    task = get_task(task_id)
    if not task:
        return JSONResponse(
            status_code=404,
            content={"success": False, "detail": "Download task not found"},
        )
    return DownloadStatusResponse(task=task)


@router.get("/downloads")
def get_all_downloads():
    return {"tasks": list_tasks()}


@router.post("/downloads/{task_id}/cancel")
def cancel_download(task_id: str):
    success = cancel_task(task_id)
    if not success:
        return JSONResponse(
            status_code=404,
            content={"success": False, "detail": "Task not found or cannot be cancelled"},
        )
    return CancelResponse(message="Download cancelled", task_id=task_id)


@router.post("/downloads/{task_id}/retry")
async def retry_download(task_id: str, background_tasks: BackgroundTasks):
    task = get_task(task_id)
    if not task:
        return JSONResponse(
            status_code=404,
            content={"success": False, "detail": "Task not found"},
        )

    task_store.update(
        task_id,
        status=DownloadStatus.QUEUED,
        progress=0.0,
        error=None,
        file_path=None,
        started_at=None,
        completed_at=None,
        retry_count=task.retry_count + 1,
    )

    background_tasks.add_task(start_download, task_id)

    task_updated = get_task(task_id)
    return DownloadCreateResponse(task_id=task_id, status=task_updated.status)
