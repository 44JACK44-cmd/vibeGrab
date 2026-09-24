import json
from pathlib import Path
from pydantic import BaseModel
from app.core.config import settings


class AppSettings(BaseModel):
    download_dir: str = str(settings.DOWNLOAD_DIR.resolve())
    max_concurrent_downloads: int = settings.MAX_CONCURRENT_DOWNLOADS
    max_file_size_mb: int = settings.MAX_FILE_SIZE_MB
    auto_open_after_download: bool = False
    prefer_best_quality: bool = True
    save_metadata: bool = True


def _get_settings_path() -> Path:
    return settings.DOWNLOAD_DIR / ".app_settings.json"


def load_settings() -> AppSettings:
    path = _get_settings_path()
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            return AppSettings(**data)
        except (json.JSONDecodeError, OSError):
            pass
    return AppSettings()


def save_settings(new_settings: AppSettings) -> AppSettings:
    path = _get_settings_path()
    path.write_text(
        json.dumps(new_settings.model_dump(), indent=2),
        encoding="utf-8",
    )
    return new_settings
