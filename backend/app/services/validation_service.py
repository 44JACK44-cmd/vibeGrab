import re
from urllib.parse import urlparse, parse_qs
from app.core.config import settings
from app.core.logging import logger


SUPPORTED_HOSTS = set(settings.ALLOWED_DOMAINS)

URL_PATTERN = re.compile(
    r"https?://(?:www\.)?[\w\-]+(\.[\w\-]+)+(/[\w\-._~:/?#\[\]@!$&\'()*+,;=%]*)?"
)


def extract_url(text: str) -> str | None:
    text = text.strip()
    match = URL_PATTERN.search(text)
    if match:
        return match.group(0)

    try:
        parsed = urlparse(text)
        if parsed.scheme in ("http", "https") and parsed.netloc:
            return text
    except Exception:
        pass

    return None


def normalize_url(url: str) -> str:
    url = url.strip()
    url = re.sub(r"\s+", "", url)

    url = re.sub(r"&t=\d+s?$", "", url)
    url = re.sub(r"&list=[\w\-]+", "", url)

    parsed = urlparse(url)

    if parsed.hostname in ("youtu.be",):
        return f"https://youtu.be{parsed.path}"

    if parsed.hostname in ("youtube.com", "www.youtube.com"):
        query = parse_qs(parsed.query)
        if "v" in query:
            video_id = query["v"][0]
            return f"https://www.youtube.com/watch?v={video_id}"

    return url


def validate_url(url: str) -> bool:
    parsed = urlparse(url)

    if parsed.scheme not in ("http", "https"):
        return False

    hostname = parsed.hostname
    if not hostname:
        return False

    if hostname in SUPPORTED_HOSTS:
        return True

    for supported in SUPPORTED_HOSTS:
        if hostname.endswith("." + supported):
            return True

    return False


def get_source(url: str) -> str:
    parsed = urlparse(url)
    hostname = parsed.hostname or ""

    hostname = hostname.replace("www.", "")

    source_map = {
        "youtube.com": "youtube",
        "youtu.be": "youtube",
        "tiktok.com": "tiktok",
        "instagram.com": "instagram",
        "twitter.com": "twitter",
        "x.com": "twitter",
        "facebook.com": "facebook",
        "vimeo.com": "vimeo",
        "dailymotion.com": "dailymotion",
        "soundcloud.com": "soundcloud",
    }

    for domain, source in source_map.items():
        if hostname == domain or hostname.endswith("." + domain):
            return source

    return "unknown"
