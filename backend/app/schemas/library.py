from pydantic import BaseModel


class LibraryFile(BaseModel):
    filename: str
    title: str
    file_path: str
    file_size: int
    file_size_formatted: str
    file_type: str
    extension: str
    created_at: str
    thumbnail: str | None = None
    source: str | None = None


class LibraryListResponse(BaseModel):
    files: list[LibraryFile]
    total: int


class LibraryDeleteResponse(BaseModel):
    success: bool
    message: str
    filename: str
