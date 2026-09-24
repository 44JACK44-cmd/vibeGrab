from pydantic_settings import BaseSettings
from pathlib import Path


class Settings(BaseSettings):
    APP_NAME: str = "VibeGrab API"
    VERSION: str = "0.2.0"
    DEBUG: bool = False

    HOST: str = "0.0.0.0"
    PORT: int = 8000

    DOWNLOAD_DIR: Path = Path("downloads")
    TEMP_DIR: Path = Path("temp")
    MAX_CONCURRENT_DOWNLOADS: int = 2
    MAX_FILE_SIZE_MB: int = 2048
    MIN_FREE_SPACE_MB: int = 500

    YT_DLP_PATH: str = "yt-dlp"
    FFMPEG_PATH: str = r"C:\Users\jacka\AppData\Local\Microsoft\WinGet\Packages\Gyan.FFmpeg_Microsoft.Winget.Source_8wekyb3d8bbwe\ffmpeg-9.0-full_build\bin\ffmpeg.exe"

    CORS_ORIGINS: str = "*"

    ALLOWED_DOMAINS: list[str] = [
        "youtube.com",
        "www.youtube.com",
        "youtu.be",
        "music.youtube.com",
        "tiktok.com",
        "www.tiktok.com",
        "vm.tiktok.com",
        "instagram.com",
        "www.instagram.com",
        "twitter.com",
        "x.com",
        "www.twitter.com",
        "www.x.com",
        "facebook.com",
        "www.facebook.com",
        "vimeo.com",
        "www.vimeo.com",
        "dailymotion.com",
        "www.dailymotion.com",
        "soundcloud.com",
        "www.soundcloud.com",
    ]

    model_config = {"env_file": ".env", "env_file_encoding": "utf-8"}

    @property
    def cors_origins_list(self) -> list[str]:
        if self.CORS_ORIGINS.strip() == "*":
            return ["*"]
        return [o.strip() for o in self.CORS_ORIGINS.split(",") if o.strip()]


settings = Settings()

settings.DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
settings.TEMP_DIR.mkdir(parents=True, exist_ok=True)
