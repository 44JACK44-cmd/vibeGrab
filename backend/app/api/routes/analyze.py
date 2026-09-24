import shutil
from contextlib import asynccontextmanager
from fastapi import APIRouter, BackgroundTasks
from fastapi.responses import JSONResponse
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


def _check_tool(name: str, path: str) -> dict:
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
            "yt_dlp": _check_tool("yt-dlp", settings.YT_DLP_PATH),
            "ffmpeg": _check_tool("ffmpeg", settings.FFMPEG_PATH),
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
