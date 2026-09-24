import subprocess
import json
from app.core.config import settings
from app.core.logging import logger
from app.schemas.explore import ExploreVideo


def search_videos(query: str, limit: int = 10) -> list[ExploreVideo]:
    cmd = [
        settings.YT_DLP_PATH,
        "--dump-json",
        "--flat-playlist",
        "--no-warnings",
        f"ytsearch{limit}:{query}",
    ]

    logger.info(f"Searching YouTube: '{query}' (limit={limit})")

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:
        raise Exception(f"yt-dlp search error: {result.stderr.strip()}")

    videos = []
    for line in result.stdout.strip().split("\n"):
        if not line.strip():
            continue
        try:
            data = json.loads(line)
            video = _parse_result(data)
            if video is not None:
                videos.append(video)
        except json.JSONDecodeError:
            continue

    return videos


def _parse_result(data: dict) -> ExploreVideo | None:
    video_id = data.get("id")
    if not video_id:
        return None

    url = data.get("url") or f"https://www.youtube.com/watch?v={video_id}"
    title = data.get("title", "Untitled")
    thumbnail = _best_thumbnail(data)
    channel = data.get("channel") or data.get("uploader")
    duration = data.get("duration")
    duration_string = data.get("duration_string")
    view_count = data.get("view_count")

    return ExploreVideo(
        id=video_id,
        title=title,
        url=url,
        thumbnail=thumbnail,
        channel=channel,
        duration=duration,
        duration_string=duration_string,
        view_count=view_count,
    )


def _best_thumbnail(data: dict) -> str | None:
    thumbnails = data.get("thumbnails", [])
    if thumbnails:
        for t in thumbnails:
            if t.get("height", 0) >= 360:
                return t.get("url")
        return thumbnails[-1].get("url")
    return data.get("thumbnail")
