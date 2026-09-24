import os
from fastapi import APIRouter
from fastapi.responses import JSONResponse, FileResponse
from app.schemas.library import LibraryListResponse, LibraryDeleteResponse
from app.services.library_service import list_library_files, delete_library_file, get_file_path
from app.core.logging import logger

router = APIRouter(prefix="/api/library")


@router.get("")
def get_library():
    return list_library_files()


@router.delete("/{filename}")
def delete_file(filename: str):
    result = delete_library_file(filename)
    if not result.success:
        return JSONResponse(status_code=404, content=result.model_dump())
    return result


@router.get("/{filename}/stream")
def stream_file(filename: str):
    file_path = get_file_path(filename)
    if not file_path:
        return JSONResponse(status_code=404, content={"detail": "File not found"})

    media_types = {
        ".mp4": "video/mp4",
        ".mkv": "video/x-matroska",
        ".webm": "video/webm",
        ".m4a": "audio/mp4",
        ".mp3": "audio/mpeg",
        ".opus": "audio/opus",
        ".wav": "audio/wav",
        ".flac": "audio/flac",
    }
    media_type = media_types.get(file_path.suffix.lower(), "application/octet-stream")

    return FileResponse(
        path=str(file_path),
        media_type=media_type,
        filename=file_path.name,
    )
