from pydantic_settings import BaseSettings
from pathlib import Path


class Settings(BaseSettings):
    APP_NAME: str = "VibeGrab API"
    VERSION: str = "0.3.0"
    DEBUG: bool = False

    HOST: str = "0.0.0.0"
    PORT: int = 8000

    DOWNLOAD_DIR: Path = Path("downloads")
    TEMP_DIR: Path = Path("temp")
    MAX_CONCURRENT_DOWNLOADS: int = 2
    MAX_FILE_SIZE_MB: int = 2048
    MIN_FREE_SPACE_MB: int = 500

    YT_DLP_PATH: str = "yt-dlp"
    FFMPEG_PATH: str = "ffmpeg"

    CORS_ORIGINS: str = "*"
    # Must stay False: allowing credentials together with a wildcard origin is
    # an invalid/insecure CORS combination. The app is native (no cookies).
    CORS_ALLOW_CREDENTIALS: bool = False

    # --- Security -------------------------------------------------------
    # When set (non-empty), every /api/* request must send this value in the
    # "X-API-Key" header. Empty = auth disabled, which keeps current clients
    # working. Enable it in Render only after the app ships with the header.
    API_KEY: str = ""

    # Per-client fixed-window rate limit (in-memory, per instance). Keep it
    # generous: mobile carriers use CGNAT, so many users can share one public
    # IP. Set RATE_LIMIT_ENABLED=false to turn it off.
    RATE_LIMIT_ENABLED: bool = True
    RATE_LIMIT_PER_MINUTE: int = 300
    RATE_LIMIT_WINDOW_SECONDS: int = 60

    # Hosts the /api/explore/proxy relay may fetch from (comma-separated
    # suffix match), e.g. "googlevideo.com,f5.si".
    RELAY_ALLOWED_HOSTS: str = "googlevideo.com,f5.si"

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

    @property
    def relay_allowed_hosts_list(self) -> list[str]:
        return [
            h.strip().lower()
            for h in self.RELAY_ALLOWED_HOSTS.split(",")
            if h.strip()
        ]


settings = Settings()

settings.DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
settings.TEMP_DIR.mkdir(parents=True, exist_ok=True)
