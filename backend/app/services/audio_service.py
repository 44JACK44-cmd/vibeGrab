"""Turn a provider's audio track into a real MP3 with tags and cover.

Why on the server: an Android app cannot execute a bundled `ffmpeg` binary, so
the Flutter client's old `Process.run('ffmpeg')` path could never work. Audio
was saved with its original extension (m4a/webm) and without a cover, while
the UI said MP3. The conversion runs here, where ffmpeg is installed (see
backend/Dockerfile), and the phone receives a finished MP3.

Nothing is re-encoded when the source is already an MP3: the bytes are copied
and the tags/cover are added.
"""

import ipaddress
import socket
import subprocess
import urllib.parse
import urllib.request
from pathlib import Path

from app.core.config import settings
from app.core.logging import logger

# Hosts we accept when the client asks us to fetch a media file directly
# (photo-post music, thumbnails). Everything else must go through yt-dlp,
# which is the extractor that decides what a provider may serve.
_DIRECT_HOST_SUFFIXES = (
    "tiktokcdn.com",
    "tiktokcdn-us.com",
    "tiktokv.com",
    "ibytedtos.com",
    "ibyteimg.com",
    "ytimg.com",
    "ggpht.com",
    "googlevideo.com",
)

_MAX_COVER_BYTES = 6 * 1024 * 1024
_MAX_AUDIO_BYTES = 300 * 1024 * 1024


class AudioConversionError(Exception):
    """The source could not be turned into a playable MP3."""


def _public_host(url: str) -> bool:
    """Reject local/private targets: the server must not fetch them."""
    try:
        parsed = urllib.parse.urlparse(url)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            return False
        infos = socket.getaddrinfo(parsed.hostname, None)
    except Exception:
        return False
    for info in infos:
        addr = ipaddress.ip_address(info[4][0])
        if addr.is_private or addr.is_loopback or addr.is_link_local:
            return False
    return True


def is_direct_media_url(url: str) -> bool:
    """True when the client may ask us to convert this URL as-is."""
    if not _media_host_allowed(url):
        return False
    return _public_host(url)


def _media_host_allowed(url: str) -> bool:
    """Pure host check (no DNS): only known media CDNs are fetched directly."""
    try:
        parsed = urllib.parse.urlparse(url)
    except Exception:
        return False
    if parsed.scheme not in ("http", "https"):
        return False
    host = (parsed.hostname or "").lower()
    if not host:
        return False
    return any(host == s or host.endswith("." + s) for s in _DIRECT_HOST_SUFFIXES)


def _download(url: str, dest: Path, limit: int, *, allowlist: bool) -> None:
    allowed = is_direct_media_url(url) if allowlist else _public_host(url)
    if not allowed:
        raise AudioConversionError("host not allowed")
    request = urllib.request.Request(url, headers={"User-Agent": "VibeGrab/1.0"})
    written = 0
    try:
        with urllib.request.urlopen(request, timeout=30) as response, open(dest, "wb") as out:
            while True:
                chunk = response.read(64 * 1024)
                if not chunk:
                    break
                written += len(chunk)
                if written > limit:
                    raise AudioConversionError("file too large")
                out.write(chunk)
    except AudioConversionError:
        raise
    except Exception as exc:  # noqa: BLE001 - surfaced with context
        raise AudioConversionError(f"download failed: {exc}") from exc
    if written == 0:
        raise AudioConversionError("empty download")


def _download_with_ytdlp(url: str, format_id: str, work: Path) -> Path:
    # Menu entries expose a synthetic ``<tag>__mp3`` id; yt-dlp expects the
    # provider's real tag.
    if format_id.endswith("__mp3"):
        format_id = format_id[: -len("__mp3")]
    cmd = [
        settings.YT_DLP_PATH,
        "-f", format_id or "bestaudio/best",
        "--no-playlist",
        "--no-warnings",
        "--no-progress",
        "--max-filesize", "300M",
        "-o", str(work / "audio.%(ext)s"),
        url,
    ]
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=180)
    except subprocess.TimeoutExpired as exc:
        raise AudioConversionError("yt-dlp timed out") from exc
    if result.returncode != 0:
        tail = (result.stderr or "").strip()[-300:]
        raise AudioConversionError(f"yt-dlp error: {tail or result.returncode}")
    found = sorted(work.glob("audio.*"))
    if not found:
        raise AudioConversionError("yt-dlp produced no file")
    return found[0]


def ffmpeg_args(
    source: Path,
    output: Path,
    *,
    title: str = "",
    artist: str = "",
    cover: Path | None = None,
    copy_audio: bool = False,
) -> list[str]:
    """ffmpeg command: MP3 with ID3v2.3 tags and, when available, a cover.

    ``copy_audio`` is used when the source already is an MP3: the frames are
    copied untouched (no quality loss) and only the tags/cover are written.
    """
    args = [settings.FFMPEG_PATH, "-y", "-i", str(source)]
    if cover is not None:
        args += ["-i", str(cover)]
    args += ["-map", "0:a:0"]
    args += ["-c:a", "copy"] if copy_audio else ["-c:a", "libmp3lame", "-q:a", "2"]
    args += ["-id3v2_version", "3"]
    if title:
        args += ["-metadata", f"title={title}"]
    if artist:
        args += ["-metadata", f"artist={artist}"]
    if cover is not None:
        args += [
            "-map", "1:v:0",
            "-c:v", "copy",
            "-metadata:s:v", "title=Album cover",
            "-metadata:s:v", "comment=Cover (front)",
            "-disposition:v:0", "attached_pic",
        ]
    args.append(str(output))
    return args


def convert_to_mp3(
    work: Path,
    *,
    url: str = "",
    format_id: str = "",
    direct_url: str = "",
    title: str = "",
    artist: str = "",
    cover_url: str = "",
) -> Path:
    """Build ``work/output.mp3`` from a provider URL or a direct media URL."""
    work.mkdir(parents=True, exist_ok=True)

    if url:
        source = _download_with_ytdlp(url, format_id, work)
    elif direct_url:
        source = work / "source.bin"
        _download(direct_url, source, _MAX_AUDIO_BYTES, allowlist=True)
    else:
        raise AudioConversionError("no source")

    return encode_mp3(
        work,
        source,
        title=title,
        artist=artist,
        cover_url=cover_url,
    )


def encode_mp3(
    work: Path,
    source: Path,
    *,
    title: str = "",
    artist: str = "",
    cover_url: str = "",
) -> Path:
    """Encode an already-local audio file into ``work/output.mp3``.

    Used by the upload route: the client downloads the track from the
    provider (its own IP is the one the signed URL is bound to) and sends the
    bytes here, where only ffmpeg is needed.
    """
    if not source.exists() or source.stat().st_size == 0:
        raise AudioConversionError("empty source")

    cover: Path | None = None
    if cover_url and _public_host(cover_url):
        try:
            cover = work / "cover.img"
            _download(cover_url, cover, _MAX_COVER_BYTES, allowlist=False)
        except AudioConversionError as exc:
            # A cover is optional: the audio must survive without it.
            logger.info(f"cover skipped: {exc}")
            cover = None

    output = work / "output.mp3"
    is_mp3 = source.suffix.lower() == ".mp3"
    try:
        result = subprocess.run(
            ffmpeg_args(
                source,
                output,
                title=title,
                artist=artist,
                cover=cover,
                copy_audio=is_mp3,
            ),
            capture_output=True,
            text=True,
            timeout=180,
        )
    except subprocess.TimeoutExpired as exc:
        raise AudioConversionError("ffmpeg timed out") from exc
    if result.returncode != 0 or not output.exists():
        tail = (result.stderr or "").strip()[-300:]
        raise AudioConversionError(f"ffmpeg failed: {tail or result.returncode}")

    if output.stat().st_size == 0:
        raise AudioConversionError("empty output")
    return output


def merge_tracks(work: Path, video: Path, audio: Path) -> tuple[Path, str]:
    """Mux a video-only track and an audio-only track without re-encoding.

    Returns ``(path, extension)``. MP4 is tried first (the format the UI
    offers); when the codecs/container combination is not MP4-compatible
    (VP9/Opus from the WebM tracks) Matroska is used instead. The file is
    real: both streams are copied and the result is never a muted video.
    """
    work.mkdir(parents=True, exist_ok=True)
    for path in (video, audio):
        if not path.exists() or path.stat().st_size == 0:
            raise AudioConversionError("empty track")

    attempts = (("mp4", ["-movflags", "+faststart"]), ("mkv", []))
    last_error = ""
    for ext, extra in attempts:
        output = work / f"output.{ext}"
        args = [
            settings.FFMPEG_PATH,
            "-y",
            "-i", str(video),
            "-i", str(audio),
            "-map", "0:v:0",
            "-map", "1:a:0",
            "-c", "copy",
            "-shortest",
            *extra,
            str(output),
        ]
        try:
            result = subprocess.run(args, capture_output=True, text=True, timeout=300)
        except subprocess.TimeoutExpired:
            last_error = "ffmpeg timed out"
            continue
        if result.returncode == 0 and output.exists() and output.stat().st_size > 0:
            return output, ext
        last_error = (result.stderr or "").strip()[-300:] or str(result.returncode)
        try:
            output.unlink(missing_ok=True)
        except OSError:
            pass

    raise AudioConversionError(f"mux failed: {last_error or 'unknown error'}")

