import uuid
import re
import subprocess
import asyncio
from datetime import datetime, timezone
from pathlib import Path
from app.core.config import settings
from app.core.logging import logger
from app.schemas.download import DownloadTask, DownloadStatus
from app.services import task_store
from app.services.library_service import save_download_metadata
from app.services.settings_service import load_settings
from app.services.processing_service import needs_processing, run_merge


_semaphore: asyncio.Semaphore | None = None


def _get_semaphore() -> asyncio.Semaphore:
    global _semaphore
    s = load_settings()
    _semaphore = asyncio.Semaphore(s.max_concurrent_downloads)
    return _semaphore


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat()


def init_store():
    """Load tasks from disk, recover interrupted, clean orphans."""
    task_store.load_all()
    recovered = task_store.recover_interrupted()
    if recovered:
        logger.info(f"Recovered {len(recovered)} interrupted downloads (marked as failed)")
    task_store.cleanup_orphans()
    logger.info("Download store initialized")


def create_task(
    url: str,
    format_id: str,
    title: str | None = None,
    has_video: bool = True,
    has_audio: bool = True,
) -> DownloadTask:
    task_id = str(uuid.uuid4())[:8]
    task = DownloadTask(
        id=task_id,
        url=url,
        title=title or "Untitled",
        format_id=format_id,
        has_video=has_video,
        has_audio=has_audio,
        status=DownloadStatus.QUEUED,
        created_at=_now_iso(),
    )
    task_store.put(task)
    return task


def get_task(task_id: str) -> DownloadTask | None:
    return task_store.get(task_id)


def list_tasks() -> list[DownloadTask]:
    return task_store.all_tasks()


def cancel_task(task_id: str) -> bool:
    task = task_store.get(task_id)
    if not task:
        return False
    if task.status in (DownloadStatus.COMPLETED, DownloadStatus.CANCELLED):
        return False

    task_store.update(
        task_id,
        status=DownloadStatus.CANCELLED,
        error="Cancelled by user",
        completed_at=_now_iso(),
        progress=0.0,
    )

    task_store.cleanup_task_files(task)
    logger.info(f"Download cancelled: {task_id}")
    return True


def _update_task(task_id: str, **kwargs) -> None:
    task_store.update(task_id, **kwargs)


def _run_download(task_id: str, url: str, format_id: str):
    task = task_store.get(task_id)
    if not task:
        return

    output_dir = settings.DOWNLOAD_DIR
    output_dir.mkdir(parents=True, exist_ok=True)
    output_template = str(output_dir / "%(title)s.%(ext)s")

    cmd = [
        settings.YT_DLP_PATH,
        "-f", format_id,
        "--no-playlist",
        "-o", output_template,
        "--newline",
        "--progress",
        "--no-overwrites",
        url,
    ]

    try:
        _update_task(task_id, status=DownloadStatus.PREPARING, started_at=_now_iso(), error=None)
        logger.info(f"Starting download: {task_id} - {task.title} [{format_id}]")

        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )

        last_file = None

        for line in process.stdout:
            task_now = task_store.get(task_id)
            if task_now and task_now.status == DownloadStatus.CANCELLED:
                process.kill()
                process.wait()
                logger.info(f"Download cancelled mid-stream: {task_id}")
                return

            line = line.strip()
            if not line:
                continue

            if "[download] Destination:" in line:
                last_file = line.split("Destination:", 1)[1].strip()

            if "[download] Merging" in line or "[Merger]" in line:
                _update_task(task_id, status=DownloadStatus.PROCESSING, progress=99.0)

            if "has already been downloaded" in line:
                _update_task(task_id, progress=100.0)

            if "%" in line:
                match = re.search(r"(\d+\.?\d*)%", line)
                if match:
                    pct = float(match.group(1))
                    _update_task(
                        task_id,
                        progress=min(pct, 99.9),
                        status=DownloadStatus.DOWNLOADING,
                    )

            if "[download] 100%" in line:
                _update_task(task_id, progress=100.0)

        process.wait()

        task_final = task_store.get(task_id)
        if task_final and task_final.status == DownloadStatus.CANCELLED:
            return

        if process.returncode != 0:
            _update_task(
                task_id,
                status=DownloadStatus.FAILED,
                error=f"yt-dlp error (code {process.returncode})",
                completed_at=_now_iso(),
            )
            logger.error(f"Download failed: {task_id} (code {process.returncode})")
            return

        file_path = last_file
        if not file_path:
            for f in output_dir.iterdir():
                if f.is_file() and f.stat().st_mtime > (datetime.now().timestamp() - 10):
                    file_path = str(f)
                    break

        _update_task(
            task_id,
            status=DownloadStatus.COMPLETED,
            progress=100.0,
            file_path=file_path,
            completed_at=_now_iso(),
            error=None,
        )
        logger.info(f"Download completed: {task_id} -> {file_path}")

        # Check if processing (FFmpeg merge) is needed
        task_check = task_store.get(task_id)
        if task_check and needs_processing(task_check):
            logger.info(f"Video-only format detected, triggering FFmpeg merge: {task_id}")
            run_merge(task_id, file_path)
            return

        if file_path:
            try:
                filename = Path(file_path).name
                task_done = task_store.get(task_id)
                save_download_metadata(
                    filename=filename,
                    title=task_done.title if task_done else Path(file_path).stem,
                    thumbnail=task_done.thumbnail if task_done else None,
                    source=task_done.source if task_done else None,
                )
            except Exception as meta_err:
                logger.error(f"Failed to save metadata for {task_id}: {meta_err}")

    except Exception as e:
        _update_task(
            task_id,
            status=DownloadStatus.FAILED,
            error=str(e),
            completed_at=_now_iso(),
        )
        logger.error(f"Download failed: {task_id} - {e}")


async def start_download(task_id: str):
    task = task_store.get(task_id)
    if not task:
        return

    sem = _get_semaphore()
    async with sem:
        await asyncio.get_event_loop().run_in_executor(
            None, _run_download, task_id, task.url, task.format_id
        )
