import json
import threading
from pathlib import Path
from app.core.config import settings
from app.core.logging import logger
from app.schemas.download import DownloadTask, DownloadStatus


_store_path: Path = settings.DOWNLOAD_DIR / ".tasks.json"
_lock = threading.Lock()
_tasks: dict[str, DownloadTask] = {}


def _save():
    try:
        data = {tid: t.model_dump() for tid, t in _tasks.items()}
        _store_path.write_text(
            json.dumps(data, indent=2, default=str),
            encoding="utf-8",
        )
    except Exception as e:
        logger.error(f"Failed to persist tasks: {e}")


def load_all() -> list[DownloadTask]:
    global _tasks
    with _lock:
        if _store_path.exists():
            try:
                raw = json.loads(_store_path.read_text(encoding="utf-8"))
                _tasks = {tid: DownloadTask(**d) for tid, d in raw.items()}
                logger.info(f"Loaded {len(_tasks)} tasks from disk")
            except (json.JSONDecodeError, OSError, Exception) as e:
                logger.error(f"Failed to load tasks: {e}")
                _tasks = {}
        else:
            _tasks = {}
        return list(_tasks.values())


def get(task_id: str) -> DownloadTask | None:
    with _lock:
        return _tasks.get(task_id)


def put(task: DownloadTask):
    with _lock:
        _tasks[task.id] = task
        _save()


def update(task_id: str, **kwargs) -> DownloadTask | None:
    with _lock:
        task = _tasks.get(task_id)
        if task:
            for key, value in kwargs.items():
                setattr(task, key, value)
            _save()
        return task


def remove(task_id: str):
    with _lock:
        _tasks.pop(task_id, None)
        _save()


def all_tasks() -> list[DownloadTask]:
    with _lock:
        return sorted(_tasks.values(), key=lambda t: t.created_at, reverse=True)


def active_tasks() -> list[DownloadTask]:
    with _lock:
        return [
            t for t in _tasks.values()
            if t.status in (
                DownloadStatus.QUEUED,
                DownloadStatus.PREPARING,
                DownloadStatus.DOWNLOADING,
                DownloadStatus.PROCESSING,
            )
        ]


def recover_interrupted() -> list[DownloadTask]:
    """On startup: mark interrupted tasks as failed so they can be retried."""
    interrupted_states = {DownloadStatus.PREPARING, DownloadStatus.DOWNLOADING, DownloadStatus.PROCESSING}
    recovered = []
    with _lock:
        for task in _tasks.values():
            if task.status in interrupted_states:
                task.status = DownloadStatus.FAILED
                task.error = "Interrupted — server restarted"
                task.progress = 0.0
                recovered.append(task)
        if recovered:
            _save()
    return recovered


def cleanup_task_files(task: DownloadTask):
    """Remove partial/temp files for a cancelled or failed task."""
    download_dir = settings.DOWNLOAD_DIR
    temp_dir = settings.TEMP_DIR

    for d in [download_dir, temp_dir]:
        if not d.exists():
            continue
        for f in d.iterdir():
            if not f.is_file():
                continue
            name_lower = f.name.lower()
            title_lower = task.title.lower()[:50]
            if title_lower and title_lower in name_lower:
                try:
                    f.unlink()
                    logger.info(f"Cleaned up: {f.name}")
                except OSError as e:
                    logger.error(f"Failed to clean {f.name}: {e}")
            elif f.suffix in ('.part', '.temp', '.ytdl'):
                try:
                    f.unlink()
                    logger.info(f"Cleaned temp: {f.name}")
                except OSError:
                    pass


def cleanup_orphans():
    """Remove .part/.temp files with no active task on startup."""
    download_dir = settings.DOWNLOAD_DIR
    temp_dir = settings.TEMP_DIR

    with _lock:
        active_titles = {t.title.lower()[:50] for t in _tasks.values() if t.status in (
            DownloadStatus.QUEUED, DownloadStatus.PREPARING,
            DownloadStatus.DOWNLOADING, DownloadStatus.PROCESSING,
        )}

    for d in [download_dir, temp_dir]:
        if not d.exists():
            continue
        for f in d.iterdir():
            if not f.is_file():
                continue
            if f.suffix in ('.part', '.temp', '.ytdl'):
                try:
                    f.unlink()
                    logger.info(f"Cleaned orphan temp: {f.name}")
                except OSError:
                    pass
