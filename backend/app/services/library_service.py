import os
import json
import stat
from pathlib import Path
from datetime import datetime, timezone
from app.core.config import settings
from app.schemas.library import LibraryFile, LibraryListResponse, LibraryDeleteResponse
from app.core.logging import logger


def _get_metadata_path() -> Path:
    return settings.DOWNLOAD_DIR / ".metadata.json"


def _load_metadata() -> dict:
    path = _get_metadata_path()
    if path.exists():
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            return {}
    return {}


def _save_metadata(data: dict):
    path = _get_metadata_path()
    path.write_text(json.dumps(data, indent=2, default=str), encoding="utf-8")


def save_download_metadata(
    filename: str,
    title: str,
    thumbnail: str | None = None,
    source: str | None = None,
):
    meta = _load_metadata()
    meta[filename] = {
        "title": title,
        "thumbnail": thumbnail,
        "source": source,
        "saved_at": datetime.now(timezone.utc).isoformat(),
    }
    _save_metadata(meta)


def _is_safe_filename(filename: str) -> bool:
    """Reject path traversal attempts like ../etc/passwd."""
    if ".." in filename or "/" in filename or "\\" in filename:
        return False
    if filename.startswith(".") and filename != ".env":
        return False
    return True


def list_library_files() -> LibraryListResponse:
    download_dir = settings.DOWNLOAD_DIR
    meta = _load_metadata()
    files: list[LibraryFile] = []

    if not download_dir.exists():
        return LibraryListResponse(files=[], total=0)

    media_exts = {".mp4", ".mkv", ".webm", ".avi", ".mov", ".m4a", ".mp3", ".opus", ".wav", ".flac"}
    skip_prefixes = (".",)
    skip_suffixes = (".part", ".temp", ".tmp", ".ytdl")

    for f in sorted(download_dir.iterdir()):
        if not f.is_file():
            continue
        if f.name.startswith(skip_prefixes):
            continue
        if f.suffix.lower() in skip_suffixes:
            continue
        if f.suffix.lower() not in media_exts:
            continue

        stat_result = f.stat()
        file_meta = meta.get(f.name, {})

        files.append(LibraryFile(
            filename=f.name,
            title=file_meta.get("title", f.stem),
            file_path=str(f.resolve()),
            file_size=stat_result.st_size,
            file_size_formatted=_format_size(stat_result.st_size),
            file_type=_get_file_type(f.suffix.lower()),
            extension=f.suffix.lower().lstrip("."),
            created_at=datetime.fromtimestamp(
                stat_result.st_mtime, tz=timezone.utc
            ).isoformat(),
            thumbnail=file_meta.get("thumbnail"),
            source=file_meta.get("source"),
        ))

    return LibraryListResponse(files=files, total=len(files))


def delete_library_file(filename: str) -> LibraryDeleteResponse:
    if not _is_safe_filename(filename):
        return LibraryDeleteResponse(
            success=False, message="Invalid filename", filename=filename
        )

    file_path = settings.DOWNLOAD_DIR / filename
    if not file_path.exists():
        return LibraryDeleteResponse(
            success=False, message="File not found", filename=filename
        )

    file_path.unlink()

    meta = _load_metadata()
    meta.pop(filename, None)
    _save_metadata(meta)

    return LibraryDeleteResponse(
        success=True, message="File deleted", filename=filename
    )


def get_file_path(filename: str) -> Path | None:
    if not _is_safe_filename(filename):
        return None

    file_path = settings.DOWNLOAD_DIR / filename
    if file_path.exists() and file_path.is_file():
        return file_path
    return None


def _format_size(size_bytes: int) -> str:
    if size_bytes < 1024:
        return f"{size_bytes} B"
    if size_bytes < 1024 * 1024:
        return f"{size_bytes / 1024:.0f} KB"
    if size_bytes < 1024 * 1024 * 1024:
        return f"{size_bytes / (1024 * 1024):.1f} MB"
    return f"{size_bytes / (1024 * 1024 * 1024):.2f} GB"


def _get_file_type(ext: str) -> str:
    video_exts = {".mp4", ".mkv", ".webm", ".avi", ".mov"}
    audio_exts = {".m4a", ".mp3", ".opus", ".wav", ".flac"}
    if ext in video_exts:
        return "video"
    if ext in audio_exts:
        return "audio"
    return "unknown"


def get_disk_space() -> dict:
    """Return download dir disk usage info."""
    download_dir = settings.DOWNLOAD_DIR
    if not download_dir.exists():
        return {"exists": False}
    stat = os.statvfs(str(download_dir))
    total = stat.f_blocks * stat.f_frsize
    free = stat.f_bavail * stat.f_frsize
    used = total - free
    return {
        "exists": True,
        "total_bytes": total,
        "used_bytes": used,
        "free_bytes": free,
        "free_formatted": _format_size(free),
        "total_formatted": _format_size(total),
        "used_formatted": _format_size(used),
    }
