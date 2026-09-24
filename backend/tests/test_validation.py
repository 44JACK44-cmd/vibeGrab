import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.validation_service import extract_url, normalize_url, validate_url


def test_extract_url_plain():
    assert extract_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ") == "https://www.youtube.com/watch?v=dQw4w9WgXcQ"


def test_extract_url_embedded():
    text = "Check this out: https://youtu.be/abc123 nice video"
    result = extract_url(text)
    assert result is not None
    assert "youtu.be" in result


def test_extract_url_no_url():
    assert extract_url("no url here") is None


def test_extract_url_empty():
    assert extract_url("") is None


def test_normalize_youtu_be():
    assert normalize_url("https://youtu.be/abc123") == "https://youtu.be/abc123"


def test_normalize_youtube_with_list():
    url = "https://www.youtube.com/watch?v=abc123&list=PLxyz"
    result = normalize_url(url)
    assert "list=" not in result
    assert "v=abc123" in result


def test_normalize_strips_timestamp():
    url = "https://www.youtube.com/watch?v=abc123&t=120s"
    result = normalize_url(url)
    assert "&t=" not in result


def test_validate_youtube():
    assert validate_url("https://www.youtube.com/watch?v=dQw4w9WgXcQ") is True


def test_validate_youtu_be():
    assert validate_url("https://youtu.be/dQw4w9WgXcQ") is True


def test_validate_tiktok():
    assert validate_url("https://www.tiktok.com/@user/video/123") is True


def test_validate_instagram():
    assert validate_url("https://www.instagram.com/p/abc123/") is True


def test_validate_twitter():
    assert validate_url("https://twitter.com/user/status/123") is True


def test_validate_x():
    assert validate_url("https://x.com/user/status/123") is True


def test_validate_facebook():
    assert validate_url("https://facebook.com/video/123") is True


def test_validate_soundcloud():
    assert validate_url("https://soundcloud.com/artist/track") is True


def test_validate_unknown_domain():
    assert validate_url("https://example.com/video") is False


def test_validate_no_scheme():
    assert validate_url("youtube.com/watch?v=123") is False


def test_validate_ftp():
    assert validate_url("ftp://youtube.com/video") is False


def test_normalize_no_whitespace():
    url = "https://www.youtube.com /watch?v=abc"
    result = normalize_url(url)
    assert " " not in result
