import subprocess
from pathlib import Path
from app.core.config import settings
from app.core.logging import logger
from app.services import task_store
from app.schemas.download import DownloadStatus


def _now_iso() -> str:
    from datetime import datetime, timezone
    return datetime.now(timezone.utc).isoformat()


def needs_processing(task) -> bool:
    """Check if a completed download needs FFmpeg processing (video-only needs audio merge)."""
    return task.has_video and not task.has_audio


def _spawn(cmd: list[str]) -> subprocess.Popen:
    return subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1,
    )


def _drain_or_cancel(proc: subprocess.Popen, task_id: str, task) -> bool:
    """Drain process output; kill it and clean temp files if cancelled.

    Returns True when the task was cancelled and the process was stopped.
    """
    for _ in proc.stdout:
        task_now = task_store.get(task_id)
        if task_now and task_now.status == DownloadStatus.CANCELLED:
            proc.kill()
            proc.wait()
            _cleanup_temp_files(task)
            return True
    proc.wait()
    return False


def _keep_video_only(task_id: str, video_file: Path) -> None:
    """Audio stage failed: keep the video-only file as the final result."""
    task_store.update(
        task_id,
        status=DownloadStatus.COMPLETED,
        progress=100.0,
        file_path=str(video_file),
        completed_at=_now_iso(),
        error=None,
    )


def _find_audio_file(temp_dir: Path, stem: str, default: Path) -> Path:
    """Return the audio file yt-dlp produced (it may change the extension)."""
    if default.exists():
        return default
    for f in temp_dir.iterdir():
        if f.stem.startswith(stem) and f.suffix in ('.m4a', '.opus', '.webm', '.mp3'):
            return f
    return default


def _download_audio(task_id: str, task, audio_path: Path) -> str:
    """Download the best audio track. Returns 'ok', 'cancelled' or 'failed'."""
    logger.info(f"Downloading audio track for merge: {task_id}")
    audio_cmd = [
        settings.YT_DLP_PATH,
        "-f", "bestaudio",
        "--no-playlist",
        "-o", str(audio_path),
        "--no-overwrites",
        "--newline",
        "--progress",
        task.url,
    ]
    proc = _spawn(audio_cmd)
    if _drain_or_cancel(proc, task_id, task):
        return "cancelled"
    return "ok" if proc.returncode == 0 else "failed"


def _merge_av(
    task_id: str, task, video_file: Path, actual_audio: Path, output_path: Path
) -> str:
    """Run the FFmpeg merge. Returns 'ok', 'cancelled' or 'failed'."""
    logger.info(f"Running FFmpeg merge: {task_id}")
    merge_cmd = [
        settings.FFMPEG_PATH,
        "-y",
        "-i", str(video_file),
        "-i", str(actual_audio),
        "-c:v", "copy",
        "-c:a", "aac",
        "-movflags", "+faststart",
        str(output_path),
    ]
    proc = _spawn(merge_cmd)
    if _drain_or_cancel(proc, task_id, task):
        return "cancelled"
    return "ok" if proc.returncode == 0 else "failed"


def _save_metadata(task_id: str, task, output_path: Path) -> None:
    try:
        from app.services.library_service import save_download_metadata

        save_download_metadata(
            filename=output_path.name,
            title=task.title,
            thumbnail=task.thumbnail,
            source=task.source,
        )
    except Exception as e:
        logger.error(f"Failed to save metadata for {task_id}: {e}")


def run_merge(task_id: str, video_path: str):
    """Download best audio and merge with video using FFmpeg."""
    task = task_store.get(task_id)
    if not task:
        return

    output_dir = settings.DOWNLOAD_DIR
    temp_dir = settings.TEMP_DIR
    temp_dir.mkdir(parents=True, exist_ok=True)

    video_file = Path(video_path)
    if not video_file.exists():
        task_store.update(
            task_id,
            status=DownloadStatus.FAILED,
            error="Video file not found for processing",
            completed_at=_now_iso(),
        )
        return

    stem = video_file.stem
    audio_path = temp_dir / f"{stem}_audio.{task.format_id}.m4a"
    output_path = output_dir / f"{stem}.mp4"

    task_store.update(task_id, status=DownloadStatus.PROCESSING, progress=0.0)
    logger.info(f"Processing: {task_id} — merging audio + video")

    try:
        audio_status = _download_audio(task_id, task, audio_path)
        if audio_status == "cancelled":
            return
        if audio_status == "failed":
            # If audio download fails, keep the video-only file as final
            logger.warning(f"Audio download failed for {task_id}, keeping video-only")
            _keep_video_only(task_id, video_file)
            return

        actual_audio = _find_audio_file(temp_dir, stem, audio_path)
        if not actual_audio.exists():
            logger.warning(f"Audio file not found for {task_id}, keeping video-only")
            _keep_video_only(task_id, video_file)
            return

        merge_status = _merge_av(task_id, task, video_file, actual_audio, output_path)
        if merge_status == "cancelled":
            return
        if merge_status == "failed":
            logger.error(f"FFmpeg merge failed for {task_id}")
            task_store.update(
                task_id,
                status=DownloadStatus.FAILED,
                error="FFmpeg merge failed",
                completed_at=_now_iso(),
            )
            _cleanup_temp_files(task)
            return

        # Step 3: Clean up temp files, update task
        _cleanup_file(video_file)
        _cleanup_file(actual_audio)

        task_store.update(
            task_id,
            status=DownloadStatus.COMPLETED,
            progress=100.0,
            file_path=str(output_path),
            completed_at=_now_iso(),
            error=None,
        )
        logger.info(f"Merge completed: {task_id} -> {output_path}")

        # Save library metadata
        _save_metadata(task_id, task, output_path)

    except Exception as e:
        task_store.update(
            task_id,
            status=DownloadStatus.FAILED,
            error=f"Processing error: {str(e)}",
            completed_at=_now_iso(),
        )
        logger.error(f"Processing failed: {task_id} — {e}")
        _cleanup_temp_files(task)


def _cleanup_file(path: Path):
    try:
        if path.exists():
            path.unlink()
    except OSError as e:
        logger.error(f"Failed to delete {path.name}: {e}")


def _cleanup_temp_files(task):
    """Remove any temp files created during processing for this task."""
    temp_dir = settings.TEMP_DIR
    if not temp_dir.exists():
        return
    stem = Path(task.file_path).stem if task.file_path else task.title[:50]
    for f in temp_dir.iterdir():
        if f.is_file() and stem in f.name:
            _cleanup_file(f)
