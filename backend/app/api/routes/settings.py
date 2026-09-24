from fastapi import APIRouter
from app.schemas.library import LibraryListResponse
from app.services.settings_service import AppSettings, load_settings, save_settings

router = APIRouter(prefix="/api/settings")


@router.get("")
def get_settings():
    return load_settings()


@router.put("")
def update_settings(new_settings: AppSettings):
    return save_settings(new_settings)
