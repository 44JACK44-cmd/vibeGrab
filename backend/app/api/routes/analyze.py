import re
import shutil
import subprocess
import threading
import uuid
from contextlib import asynccontextmanager
from pathlib import Path
from fastapi import APIRouter, BackgroundTasks, File, Query, UploadFile
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
from app.services.audio_service import (
    AudioConversionError,
    convert_to_mp3,
    encode_mp3,
    merge_tracks,
)
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


_MAX_UPLOAD_BYTES = 300 * 1024 * 1024


def _host(url: str) -> str:
    """Host only: signed URLs must never reach the logs."""
    try:
        return re.sub(r"[^A-Za-z0-9.\-]", "", url.split("/")[2])[:80]
    except Exception:
        return "?"


def _error(
    status: int,
    code: str,
    detail: str,
    *,
    stage: str,
    request_id: str | None = None,
):
    """One error shape for every download pipeline stage.

    The client turns ``error_code`` into a specific user message and keeps
    ``detail`` + ``request_id`` for the technical log, so a failure is never
    hidden behind a generic "server error".
    """
    rid = request_id or uuid.uuid4().hex[:12]
    logger.warning(
        f"[{rid}] stage={stage} code={code} status={status} detail={detail[:300]}"
    )
    return JSONResponse(
        status_code=status,
        content={
            "success": False,
            "error_code": code,
            "stage": stage,
            "detail": detail,
            "request_id": rid,
        },
        headers={"X-Request-ID": rid},
    )


async def _save_upload(upload: UploadFile, dest: Path, limit: int = _MAX_UPLOAD_BYTES) -> int:
    written = 0
    with dest.open("wb") as out:
        while True:
            chunk = await upload.read(1024 * 1024)
            if not chunk:
                break
            written += len(chunk)
            if written > limit:
                raise ValueError("file too large")
            out.write(chunk)
    return written


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
        return _error(400, "invalid_request", "No valid URL found in input", stage="normalize")

    url = normalize_url(raw_url)

    if not validate_url(url):
        return _error(
            400, "unsupported_url", "Unsupported or invalid URL", stage="normalize"
        )

    try:
        media, formats = extract_media_info(url)
    except Exception as e:
        logger.error(f"Extraction failed for {_host(url)}: {e}")
        return _error(
            422,
            "source_unavailable",
            f"Could not extract media info: {str(e)[:300]}",
            stage="extract",
        )

    if not formats:
        return _error(
            422, "no_formats", "No downloadable formats found", stage="extract"
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
        return _error(
            400, "invalid_request", "No valid URL found in input", stage="validate"
        )
    target = normalize_url(raw_url)
    if not validate_url(target):
        return _error(
            400, "unsupported_url", "Unsupported or invalid URL", stage="validate"
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
        return _error(
            400, "invalid_format", "Invalid format id", stage="validate"
        )

    logger.info(f"Streaming fetch: {_host(target)} format={format_id}")

    proc = _spawn_fetch(target, format_id)

    stderr_buf: list[bytes] = []
    threading.Thread(
        target=_drain_stderr, args=(proc, stderr_buf), daemon=True
    ).start()

    first = proc.stdout.read(65536)
    if not first:
        proc.wait(timeout=30)
        tail = _stderr_tail(stderr_buf)
        logger.error(f"Fetch failed for {_host(target)}: {tail[:200]}")
        return _error(
            502,
            "source_unavailable",
            f"Extractor failed: {tail or 'unknown error'}",
            stage="extract",
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
        return _error(400, "invalid_request", "Missing source", stage="validate")
    if url:
        target = _validate_fetch_target(url)
        if isinstance(target, JSONResponse):
            return target
        url = target
    if format_id and not re.fullmatch(r"[A-Za-z0-9_.+-]+", format_id):
        return _error(400, "invalid_format", "Invalid format id", stage="validate")

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
        logger.error(f"Audio conversion failed ({_host(url or direct)}): {exc}")
        return _error(
            502,
            "conversion_failed",
            f"Conversion failed: {exc}",
            stage="convert",
        )

    background_tasks.add_task(shutil.rmtree, work, ignore_errors=True)
    filename = _safe_filename(title) + ".mp3"
    return FileResponse(
        output,
        media_type="audio/mpeg",
        filename=filename,
        headers={"X-VibeGrab-Format": "mp3"},
    )


@router.post("/convert/audio")
async def convert_audio_upload(
    background_tasks: BackgroundTasks,
    audio: UploadFile = File(...),
    title: str = Query("", max_length=200),
    artist: str = Query("", max_length=200),
    cover: str = Query("", max_length=2048),
    ext: str = Query("", max_length=8),
):
    """Encode MP3 from bytes the client already downloaded.

    Why this route exists: the production host cannot always reach a
    provider's media servers (the provider blocks datacenter IPs), while the
    phone can. The phone downloads the audio track with its own signed URL and
    posts it here; ffmpeg is the only thing the server is needed for. No
    provider extraction and no signed URL ever leave the device.

    The part is multipart (`audio`), the same shape as `/merge`, because the
    app uploads with one code path for both.
    """
    rid = uuid.uuid4().hex[:12]
    safe_ext = ext.lower() if re.fullmatch(r"[a-z0-9]{1,5}", ext.lower()) else "bin"
    work = Path(settings.TEMP_DIR) / f"upload-mp3-{rid}"
    try:
        work.mkdir(parents=True, exist_ok=True)
        source = work / f"source.{safe_ext}"
        written = await _save_upload(audio, source)
        if written == 0:
            raise AudioConversionError("empty upload")
        output = encode_mp3(
            work, source, title=title, artist=artist, cover_url=cover
        )
    except ValueError as exc:
        shutil.rmtree(work, ignore_errors=True)
        return _error(413, "file_too_large", str(exc), stage="upload", request_id=rid)
    except AudioConversionError as exc:
        shutil.rmtree(work, ignore_errors=True)
        logger.error(f"[{rid}] Upload conversion failed: {exc}")
        return _error(
            422,
            "conversion_failed",
            f"Conversion failed: {exc}",
            stage="convert",
            request_id=rid,
        )
    except Exception as exc:  # noqa: BLE001 - contract must stay stable
        shutil.rmtree(work, ignore_errors=True)
        logger.exception(f"[{rid}] Upload conversion crashed")
        return _error(
            500,
            "internal_error",
            f"Unexpected error: {type(exc).__name__}",
            stage="convert",
            request_id=rid,
        )

    background_tasks.add_task(shutil.rmtree, work, ignore_errors=True)
    logger.info(f"[{rid}] Upload converted to MP3 ({written} bytes in)")
    return FileResponse(
        output,
        media_type="audio/mpeg",
        filename=_safe_filename(title) + ".mp3",
        headers={"X-VibeGrab-Format": "mp3", "X-Request-ID": rid},
    )


@router.post("/merge")
async def merge_media(
    background_tasks: BackgroundTasks,
    video: UploadFile = File(...),
    audio: UploadFile = File(...),
    title: str = Query("", max_length=200),
):
    """Mux two device-downloaded tracks (video-only + audio-only) for real.

    Same reason as the upload conversion: yt-dlp on the server may be unable
    to reach the provider, but the phone already has the exact tracks. The
    result is a real container with both streams, never a muted video saved
    as if it had sound.
    """
    rid = uuid.uuid4().hex[:12]
    work = Path(settings.TEMP_DIR) / f"upload-merge-{rid}"
    try:
        work.mkdir(parents=True, exist_ok=True)
        video_path = work / "video.bin"
        audio_path = work / "audio.bin"
        await _save_upload(video, video_path)
        await _save_upload(audio, audio_path)
        output, ext = merge_tracks(work, video_path, audio_path)
    except ValueError as exc:
        shutil.rmtree(work, ignore_errors=True)
        return _error(413, "file_too_large", str(exc), stage="upload", request_id=rid)
    except AudioConversionError as exc:
        shutil.rmtree(work, ignore_errors=True)
        logger.error(f"[{rid}] Upload merge failed: {exc}")
        return _error(
            422, "merge_failed", f"Merge failed: {exc}", stage="merge", request_id=rid
        )
    except Exception as exc:  # noqa: BLE001 - contract must stay stable
        shutil.rmtree(work, ignore_errors=True)
        logger.exception(f"[{rid}] Upload merge crashed")
        return _error(
            500,
            "internal_error",
            f"Unexpected error: {type(exc).__name__}",
            stage="merge",
            request_id=rid,
        )

    background_tasks.add_task(shutil.rmtree, work, ignore_errors=True)
    logger.info(f"[{rid}] Upload merged to {ext}")
    return FileResponse(
        output,
        media_type="video/mp4" if ext == "mp4" else "video/x-matroska",
        filename=_safe_filename(title) + f".{ext}",
        headers={"X-VibeGrab-Format": ext, "X-Request-ID": rid},
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
