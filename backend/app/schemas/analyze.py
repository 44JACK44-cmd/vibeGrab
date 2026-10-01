from pydantic import BaseModel


class AnalyzeRequest(BaseModel):
    url: str


class MediaInfo(BaseModel):
    id: str
    title: str
    thumbnail: str | None = None
    duration: int | None = None
    uploader: str | None = None
    source: str
    platform: str | None = None


class FormatOption(BaseModel):
    id: str
    type: str  # "audio" | "video"
    extension: str
    quality: str | None = None
    has_video: bool
    has_audio: bool
    size_bytes: int | None = None
    direct_url: str | None = None


class AnalyzeResponse(BaseModel):
    success: bool = True
    media: MediaInfo
    formats: list[FormatOption]


class ErrorResponse(BaseModel):
    success: bool = False
    detail: str
    code: str | None = None
