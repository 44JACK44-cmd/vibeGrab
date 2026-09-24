from pydantic import BaseModel
from enum import Enum


class DownloadStatus(str, Enum):
    QUEUED = "queued"
    PREPARING = "preparing"
    DOWNLOADING = "downloading"
    PROCESSING = "processing"
    COMPLETED = "completed"
    PAUSED = "paused"
    CANCELLED = "cancelled"
    FAILED = "failed"


class DownloadRequest(BaseModel):
    url: str
    format_id: str
    title: str | None = None
    thumbnail: str | None = None
    source: str | None = None
    has_video: bool = True
    has_audio: bool = True


class DownloadTask(BaseModel):
    id: str
    url: str
    title: str
    format_id: str
    thumbnail: str | None = None
    source: str | None = None
    has_video: bool = True
    has_audio: bool = True
    status: DownloadStatus
    progress: float = 0.0
    bytes_downloaded: int = 0
    total_bytes: int | None = None
    file_path: str | None = None
    error: str | None = None
    retry_count: int = 0
    created_at: str
    started_at: str | None = None
    completed_at: str | None = None


class DownloadCreateResponse(BaseModel):
    task_id: str
    status: DownloadStatus


class DownloadStatusResponse(BaseModel):
    task: DownloadTask


class CancelResponse(BaseModel):
    message: str
    task_id: str
