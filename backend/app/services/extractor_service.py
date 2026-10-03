import subprocess
import json
import re
import html as htmllib
from urllib.parse import urlparse, parse_qs, unquote
from app.core.config import settings
from app.core.logging import logger
from app.schemas.analyze import MediaInfo, FormatOption

_KWAI_HOST_SUFFIXES = ("kwai.com", "kuaishou.com")
_KWAI_HOST_SUBSTRINGS = ("kwai", "kuaishou")
_KWAI_MOBILE_UA = (
    "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
)
_ISO_DURATION = re.compile(r"^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$")


def is_kwai_url(url: str) -> bool:
    try:
        host = (urlparse(url).hostname or "").lower()
    except Exception:
        return False
    if not host:
        return False
    if host.endswith(_KWAI_HOST_SUFFIXES):
        return True
    return any(token in host for token in _KWAI_HOST_SUBSTRINGS)


def _iso_to_seconds(value: str | None) -> int | None:
    if not value:
        return None
    m = _ISO_DURATION.match(value)
    if not m:
        return None
    hours, minutes, seconds = (int(g) if g else 0 for g in m.groups())
    total = hours * 3600 + minutes * 60 + seconds
    return total or None


def parse_kwai_page(page_html: str, url: str) -> dict:
    """Pull video metadata out of a Kwai SSR page. Raises if nothing found."""

    def og(name: str) -> str | None:
        m = re.search(
            r'<meta[^>]*property="%s"[^>]*content="([^"]*)"' % re.escape(name),
            page_html,
        )
        return htmllib.unescape(m.group(1).strip()) if m else None

    mp4s = re.findall(r'https://[^"\'\s]+?\.mp4[^"\'\s]*', page_html)
    if not mp4s:
        raise Exception("No video URL found in Kwai page")

    thumbnail = og("og:image") or ""
    video_url = mp4s[0]
    if thumbnail:
        image_id = thumbnail.rsplit("/", 1)[-1].split("_")[0]
        if image_id:
            for candidate in mp4s:
                if image_id in candidate:
                    video_url = candidate
                    break

    caption = og("og:description") or ""
    author_m = re.search(r'"author":"([^"]+)"', page_html)
    username_m = re.search(r"/@([^/?#]+)", url)
    uploader = (
        author_m.group(1)
        if author_m
        else (username_m.group(1) if username_m else None)
    )
    title = caption.strip() or (f"@{uploader} on Kwai" if uploader else "Kwai video")

    dur_m = re.search(r'"duration":"(PT[^"]+)"', page_html)
    duration = _iso_to_seconds(dur_m.group(1) if dur_m else None)

    dims_m = re.search(r'"width":(\d+),"height":(\d+)', page_html)
    height = int(dims_m.group(2)) if dims_m else None

    id_m = re.search(r"/(?:video|photo)/(\d+)", url)
    video_id = id_m.group(1) if id_m else str(abs(hash(url)) % 10**12)

    return {
        "id": video_id,
        "title": title,
        "thumbnail": thumbnail or None,
        "duration": duration,
        "uploader": uploader,
        "height": height,
        "url": video_url,
    }


_KWAI_IN_TEXT = re.compile(
    r'https?://(?:[\w-]+\.)*(?:kwai|kuaishou)\.com[^"\'\s<>\\]*'
)


def _resolve_kwai_target(final_url: str, page_text: str) -> str | None:
    """Recover the real Kwai page URL from short-link redirect pages.

    Short links (kwai-video.com/p/...) bounce through an AppsFlyer
    onelink page that embeds the target URL either percent-encoded in
    the query string or raw inside its JS.
    """
    try:
        query = parse_qs(urlparse(final_url).query)
        for key in ("af_sub1", "target_url", "deep_link_value", "af_dp"):
            for value in query.get(key, []):
                for m in _KWAI_IN_TEXT.finditer(unquote(value)):
                    candidate = m.group(0).rstrip("\\,;")
                    if is_kwai_url(candidate):
                        return candidate
    except Exception:
        pass

    for text in (page_text, unquote(page_text)):
        m = _KWAI_IN_TEXT.search(text)
        if m:
            candidate = m.group(0).rstrip("\\,;")
            if is_kwai_url(candidate):
                return candidate
    return None


def extract_kwai(url: str, _hop: int = 0) -> tuple[MediaInfo, list[FormatOption]]:
    from curl_cffi import requests as cffi_requests

    logger.info(f"Running Kwai extractor for: {url}")
    response = cffi_requests.get(
        url,
        impersonate="chrome",
        headers={"User-Agent": _KWAI_MOBILE_UA},
        timeout=30,
        allow_redirects=True,
    )
    if response.status_code >= 400:
        raise Exception(f"Kwai page returned HTTP {response.status_code}")

    final_url = str(getattr(response, "url", None) or url)

    try:
        meta = parse_kwai_page(response.text, final_url)
    except Exception:
        target = _resolve_kwai_target(final_url, response.text)
        if target and _hop < 3 and target.rstrip("/") != url.rstrip("/"):
            logger.info(f"Kwai short link resolved to: {target}")
            return extract_kwai(target, _hop=_hop + 1)
        raise

    size_bytes = None
    try:
        head = cffi_requests.head(
            meta["url"],
            impersonate="chrome",
            timeout=10,
            allow_redirects=True,
        )
        size_bytes = int(head.headers.get("content-length") or 0) or None
    except Exception:
        size_bytes = None

    media = MediaInfo(
        id=meta["id"],
        title=meta["title"],
        thumbnail=meta["thumbnail"],
        duration=meta["duration"],
        uploader=meta["uploader"],
        source="kwai",
        platform="kwai",
    )
    fmt = FormatOption(
        id="direct-mp4",
        type="video",
        extension="mp4",
        quality=f"{meta['height']}p" if meta["height"] else "hd",
        has_video=True,
        has_audio=True,
        size_bytes=size_bytes,
        direct_url=meta["url"],
    )
    return media, [fmt]


def extract_info(url: str) -> dict:
    # From datacenter IPs YouTube rejects the web player page ("Failed to
    # extract any player response"); the android/tv innertube clients still
    # answer, so try them first and fall back to the default client.
    last_error = ""
    for client in ("android", "tv", None):
        cmd = [
            settings.YT_DLP_PATH,
            "--dump-json",
            "--no-download",
            "--no-warnings",
            "--no-playlist",
        ]
        if client:
            cmd += ["--extractor-args", f"youtube:player_client={client}"]
        cmd.append(url)

        logger.info(f"Running extractor for: {url} (client={client or 'default'})")
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=45,
            )
        except subprocess.TimeoutExpired:
            last_error = "yt-dlp timed out"
            continue

        if result.returncode == 0 and result.stdout.strip():
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError:
                last_error = "invalid json from yt-dlp"
                continue
        last_error = result.stderr.strip()[:500]

    raise Exception(f"yt-dlp error: {last_error}")


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

    if is_kwai_url(url):
        return extract_kwai(url)

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
