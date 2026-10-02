import subprocess
import json
from app.core.config import settings
from app.core.logging import logger
from app.schemas.analyze import MediaInfo, FormatOption


def extract_info(url: str) -> dict:
    cmd = [
        settings.YT_DLP_PATH,
        "--dump-json",
        "--no-download",
        "--no-warnings",
        "--no-playlist",
        url,
    ]

    logger.info(f"Running extractor for: {url}")

    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=60,
    )

    if result.returncode != 0:
        raise Exception(f"yt-dlp error: {result.stderr.strip()}")

    return json.loads(result.stdout)


def _best_thumbnail(data: dict) -> str | None:
    thumbnails = data.get("thumbnails", [])
    if thumbnails:
        for t in thumbnails:
            if (t.get("height") or 0) >= 360:
                return t.get("url")
        return thumbnails[-1].get("url")
    return data.get("thumbnail")


def _normalize_format(fmt: dict) -> FormatOption | None:
    format_id = fmt.get("format_id", "")
    ext = fmt.get("ext", "mp4")
    height = fmt.get("height")
    vcodec = fmt.get("vcodec", "none")
    acodec = fmt.get("acodec", "none")

    has_video = vcodec != "none" and height is not None
    has_audio = acodec != "none"

    if not has_video and not has_audio:
        return None

    url = fmt.get("url") or ""
    protocol = str(fmt.get("protocol") or "")
    if not url.startswith(("http://", "https://")):
        return None
    if "m3u8" in protocol or "m3u8" in url or "dash" in protocol:
        return None

    size = fmt.get("filesize") or fmt.get("filesize_approx")

    if has_video and has_audio:
        return FormatOption(
            id=format_id,
            type="video",
            extension=ext,
            quality=f"{height}p",
            has_video=True,
            has_audio=True,
            size_bytes=size,
            direct_url=url,
        )

    if has_video and not has_audio:
        return FormatOption(
            id=format_id,
            type="video",
            extension=ext,
            quality=f"{height}p",
            has_video=True,
            has_audio=False,
            size_bytes=size,
            direct_url=url,
        )

    if not has_video and has_audio:
        abr = fmt.get("abr")
        quality = f"{int(abr)}kbps" if abr else "audio"
        return FormatOption(
            id=format_id,
            type="audio",
            extension=ext,
            quality=quality,
            has_video=False,
            has_audio=True,
            size_bytes=size,
            direct_url=url,
        )

    return None


def _pick_best_formats(raw_formats: list[dict]) -> list[FormatOption]:
    audio_by_quality: dict[str, FormatOption] = {}
    video_combined: dict[int, FormatOption] = {}
    video_only: dict[int, FormatOption] = {}

    for fmt in raw_formats:
        normalized = _normalize_format(fmt)
        if normalized is None:
            continue

        height = fmt.get("height")

        if normalized.type == "audio":
            abr = fmt.get("abr") or 0
            key = normalized.quality or ""
            if key not in audio_by_quality or abr > 0:
                audio_by_quality[key] = normalized

        elif normalized.has_audio and height:
            size = fmt.get("filesize") or fmt.get("filesize_approx") or 0
            if height not in video_combined or size > 0:
                video_combined[height] = normalized

        elif not normalized.has_audio and height:
            if height not in video_only:
                video_only[height] = normalized

    formats: list[FormatOption] = []

    def _audio_sort_key(q: str) -> int:
        if q.endswith("kbps"):
            try:
                return int(q[:-4])
            except ValueError:
                return 0
        return 0

    for q in sorted(audio_by_quality.keys(), key=_audio_sort_key, reverse=True):
        formats.append(audio_by_quality[q])

    for h in sorted(video_combined.keys(), reverse=True):
        formats.append(video_combined[h])

    for h in sorted(video_only.keys(), reverse=True):
        formats.append(video_only[h])

    return formats


def extract_media_info(url: str) -> tuple[MediaInfo, list[FormatOption]]:
    from app.services.validation_service import get_source

    data = extract_info(url)

    media_id = data.get("id", "unknown")
    title = data.get("title", "Untitled")
    thumbnail = _best_thumbnail(data)
    duration = data.get("duration")
    if duration is not None:
        try:
            duration = int(duration)
        except (TypeError, ValueError):
            duration = None
    uploader = data.get("uploader") or data.get("channel")
    source = get_source(url)
    if source == "unknown":
        source = str(data.get("extractor") or "unknown").lower()

    media = MediaInfo(
        id=media_id,
        title=title,
        thumbnail=thumbnail,
        duration=duration,
        uploader=uploader,
        source=source,
        platform=source,
    )

    raw_formats = data.get("formats", [])
    formats = _pick_best_formats(raw_formats)

    if not formats:
        raise Exception("No downloadable formats found")

    return media, formats
