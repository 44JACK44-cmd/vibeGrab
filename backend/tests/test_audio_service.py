"""MP3 conversion: the arguments we hand to ffmpeg and the safety guards.

The end-to-end test (real ffmpeg, real ID3 tags) skips itself when no ffmpeg
binary is available, so the suite stays runnable on a bare machine.
"""

import shutil
import subprocess
from pathlib import Path

import pytest

from app.core.config import settings
from app.services import audio_service as audio


def test_ffmpeg_args_encode_mp3_and_write_tags():
    args = audio.ffmpeg_args(Path("in.m4a"), Path("out.mp3"), title="T", artist="A")

    assert args[0] == settings.FFMPEG_PATH
    assert "libmp3lame" in args
    assert "-id3v2_version" in args and args[args.index("-id3v2_version") + 1] == "3"
    assert "title=T" in args
    assert "artist=A" in args
    assert "attached_pic" not in args


def test_ffmpeg_args_attach_the_cover_as_a_picture():
    args = audio.ffmpeg_args(
        Path("in.m4a"), Path("out.mp3"), title="T", cover=Path("c.jpg")
    )

    assert "c.jpg" in args
    assert "-map" in args
    assert "1:v:0" in args
    assert "attached_pic" in args


def test_ffmpeg_args_copy_already_mp3_sources():
    args = audio.ffmpeg_args(Path("in.mp3"), Path("out.mp3"), copy_audio=True)

    assert "-c:a" in args
    assert args[args.index("-c:a") + 1] == "copy"
    assert "libmp3lame" not in args


def test_direct_media_url_only_accepts_known_cdns(monkeypatch):
    # The allowlist is a pure host check: no DNS involved.
    assert audio._media_host_allowed("https://p16-sign.tiktokcdn.com/obj/music.mp3")
    assert audio._media_host_allowed("https://i.ytimg.com/vi/abc/hq.jpg")
    assert not audio._media_host_allowed("https://evil.example.com/a.mp3")
    assert not audio._media_host_allowed("file:///etc/passwd")

    # The combination also refuses private targets.
    monkeypatch.setattr(audio, "_public_host", lambda url: False)
    assert not audio.is_direct_media_url("https://p16-sign.tiktokcdn.com/m.mp3")


def test_public_host_rejects_private_targets():
    assert audio._public_host("http://127.0.0.1/a.jpg") is False
    assert audio._public_host("http://10.0.0.5/a.jpg") is False
    assert audio._public_host("http://localhost/a.jpg") is False
    assert audio._public_host("ftp://example.com/a.jpg") is False


def test_convert_requires_a_source(tmp_path):
    with pytest.raises(audio.AudioConversionError):
        audio.convert_to_mp3(tmp_path)


def test_convert_runs_ffmpeg_with_the_cover(monkeypatch, tmp_path):
    """The pipeline: download → ffmpeg → output. ffmpeg and the download are
    stubbed so the test asserts the wiring (and the args) without binaries."""

    source = tmp_path / "audio.m4a"
    source.write_bytes(b"fake audio")
    cover = tmp_path / "cover.img"
    cover.write_bytes(b"fake cover")

    monkeypatch.setattr(audio, "_download_with_ytdlp", lambda url, fid, work: source)

    def fake_download(url, dest, limit, *, allowlist):
        dest.write_bytes(b"cover" if allowlist is False else b"audio")

    monkeypatch.setattr(audio, "_download", fake_download)

    captured = {}

    def fake_run(cmd, **kwargs):
        captured["cmd"] = cmd
        Path(cmd[-1]).write_bytes(b"ID3 fake mp3")

        class _Result:
            returncode = 0
            stderr = ""

        return _Result()

    monkeypatch.setattr(audio.subprocess, "run", fake_run)

    out = audio.convert_to_mp3(
        tmp_path,
        url="https://www.youtube.com/watch?v=abc",
        format_id="140",
        title="Song",
        artist="Channel",
        cover_url="https://i.ytimg.com/vi/abc/hq.jpg",
    )

    assert out == tmp_path / "output.mp3"
    assert out.read_bytes() == b"ID3 fake mp3"
    assert any("cover.img" in arg for arg in captured["cmd"])
    assert any(arg == "title=Song" for arg in captured["cmd"])


def _ffmpeg() -> str | None:
    return shutil.which(settings.FFMPEG_PATH) or (
        settings.FFMPEG_PATH if Path(settings.FFMPEG_PATH).exists() else None
    )


@pytest.mark.skipif(_ffmpeg() is None, reason="no ffmpeg available")
def test_real_conversion_produces_a_tagged_mp3_with_cover(tmp_path):
    """Real ffmpeg: a playable MP3 carrying the title, the artist and a cover."""
    ffmpeg = _ffmpeg()
    assert ffmpeg is not None
    source = tmp_path / "tone.m4a"
    cover = tmp_path / "cover.jpg"

    subprocess.run(
        [
            ffmpeg, "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=2",
            "-c:a", "aac", str(source),
        ],
        capture_output=True,
        check=True,
    )
    subprocess.run(
        [
            ffmpeg, "-y", "-f", "lavfi", "-i", "color=c=blue:s=64x64:d=1",
            "-frames:v", "1", str(cover),
        ],
        capture_output=True,
        check=True,
    )

    out = tmp_path / "out.mp3"
    result = subprocess.run(
        audio.ffmpeg_args(source, out, title="Titulo", artist="Artista", cover=cover),
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr

    from mutagen.id3 import ID3
    from mutagen.mp3 import MP3

    assert MP3(str(out)).info.length > 1
    tags = ID3(str(out))
    assert str(tags.get("TIT2")) == "Titulo"
    assert str(tags.get("TPE1")) == "Artista"
    covers = tags.getall("APIC")
    assert covers and covers[0].mime == "image/jpeg" and len(covers[0].data) > 0
