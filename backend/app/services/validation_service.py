import ipaddress
import re
from urllib.parse import urlparse, parse_qs
from app.core.logging import logger


URL_PATTERN = re.compile(
    r"https?://(?:www\.)?[\w\-]+(\.[\w\-]+)+(/[\w\-._~:/?#\[\]@!$&\'()*+,;=%]*)?"
)

_BLOCKED_HOST_SUFFIXES = (
    ".localhost", ".local", ".internal", ".lan", ".home",
    ".test", ".example", ".invalid",
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


def _is_forbidden_host(hostname: str) -> bool:
    """Block localhost / private / reserved targets (SSRF guard).

    Everything else is allowed: yt-dlp decides whether the site is supported.
    """
    host = hostname.lower().rstrip(".")
    if host == "localhost" or host.endswith(_BLOCKED_HOST_SUFFIXES):
        return True
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        return False
    return (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_reserved
        or ip.is_multicast
        or ip.is_unspecified
    )


def validate_url(url: str) -> bool:
    parsed = urlparse(url)

    if parsed.scheme not in ("http", "https"):
        return False

    hostname = parsed.hostname
    if not hostname:
        return False

    return not _is_forbidden_host(hostname)


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
        "kwai.com": "kwai",
        "kuaishou.com": "kuaishou",
        "reddit.com": "reddit",
        "pinterest.com": "pinterest",
        "twitch.tv": "twitch",
        "snapchat.com": "snapchat",
        "linkedin.com": "linkedin",
        "9gag.com": "9gag",
        "ted.com": "ted",
        "bilibili.com": "bilibili",
    }

    for domain, source in source_map.items():
        if hostname == domain or hostname.endswith("." + domain):
            return source

    return "unknown"
