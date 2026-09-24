import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.validation_service import extract_url, normalize_url, validate_url, get_source


def test_get_source_youtube():
    assert get_source("https://www.youtube.com/watch?v=abc") == "youtube"
    assert get_source("https://youtu.be/abc") == "youtube"


def test_get_source_tiktok():
    assert get_source("https://www.tiktok.com/@user/video/123") == "tiktok"


def test_get_source_instagram():
    assert get_source("https://www.instagram.com/p/abc/") == "instagram"


def test_get_source_twitter():
    assert get_source("https://twitter.com/user/status/123") == "twitter"
    assert get_source("https://x.com/user/status/123") == "twitter"


def test_get_source_facebook():
    assert get_source("https://facebook.com/video/123") == "facebook"


def test_get_source_vimeo():
    assert get_source("https://vimeo.com/123456") == "vimeo"


def test_get_source_dailymotion():
    assert get_source("https://dailymotion.com/video/abc") == "dailymotion"


def test_get_source_soundcloud():
    assert get_source("https://soundcloud.com/artist/track") == "soundcloud"


def test_get_source_unknown():
    assert get_source("https://example.com/video") == "unknown"


def test_extract_url_with_malformed_url():
    assert extract_url("not a url at all") is None
