import json
import re
from pathlib import Path

from app.services.youtube_watch_service import (
    extract_comment_token,
    extract_innertube,
    parse_comments,
    parse_related,
)

FIXTURES = Path(__file__).parent / "fixtures"
VIDEO_ID = "dQw4w9WgXcQ"


def _load(name: str):
    with open(FIXTURES / name, encoding="utf-8") as f:
        return json.load(f)


def test_extract_innertube_from_html_snippet():
    html = (FIXTURES / "innertube_config_snippet.html").read_text(encoding="utf-8")
    cfg = extract_innertube(html)
    assert cfg["api_key"].startswith("AIza")
    assert cfg["visitor"]
    assert cfg["context"]["client"]["clientName"] == "WEB"
    assert cfg["context"]["client"]["clientVersion"]


def test_parse_related_returns_valid_items():
    initial = _load(f"watch_related_{VIDEO_ID}.json")
    items = parse_related(initial, exclude_id=VIDEO_ID)

    assert len(items) >= 10
    assert VIDEO_ID not in [i["id"] for i in items]
    for item in items:
        assert re.fullmatch(r"[A-Za-z0-9_-]{11}", item["id"]), item
        assert item["title"], item
        assert item["thumbnail"] == (
            f"https://i.ytimg.com/vi/{item['id']}/hqdefault.jpg"
        )
        if item["duration"]:
            assert re.fullmatch(r"\d+(?::\d+)+", item["duration"]), item


def test_parse_related_known_entries():
    initial = _load(f"watch_related_{VIDEO_ID}.json")
    items = {i["id"]: i for i in parse_related(initial, exclude_id=VIDEO_ID)}

    known = items.get("yPYZpwSpKmA")
    assert known is not None, "expected Rick Astley related video"
    assert "Together Forever" in known["title"]
    assert known["channel"] == "Rick Astley"
    assert known["views"]
    assert known["duration"]


def test_parse_related_all_have_channel_and_duration():
    initial = _load(f"watch_related_{VIDEO_ID}.json")
    items = parse_related(initial, exclude_id=VIDEO_ID)
    with_channel = [i for i in items if i["channel"]]
    with_duration = [i for i in items if i["duration"]]
    assert len(with_channel) >= 10
    assert len(with_duration) >= 10
    # accented titles survive intact (no mojibake)
    accented = [i for i in items if any(c in i["title"] for c in "áéíóúñÁÉÍÓÚÑ")]
    assert accented, "expected at least one accented related title"


def test_extract_comment_token():
    panels = _load(f"next_panels_{VIDEO_ID}.json")
    token = extract_comment_token(panels)
    assert token
    assert len(token) > 50
    assert token.startswith("Eg")


def test_parse_comments_page():
    payload = _load(f"next_comments_{VIDEO_ID}.json")
    items, next_token = parse_comments(payload)

    assert len(items) == 20
    assert next_token and len(next_token) > 50

    first = items[0]
    assert first["author"] == "@YouTube"
    assert "never gave us up" in first["text"]
    assert first["pinned_text"] and "Pinned by" in first["pinned_text"]
    assert first["likes"] == "322K"
    assert first["replies"] == "962"
    assert first["verified"] is True

    for item in items:
        assert item["author"], item
        assert item["text"], item
        assert item["avatar"] is None or item["avatar"].startswith("https://")


def test_parse_comments_preserves_unicode():
    payload = _load(f"next_comments_{VIDEO_ID}.json")
    items, _ = parse_comments(payload)
    for item in items:
        assert "Ã" not in item["text"], item
        assert "�" not in item["text"], item


def test_parse_comments_page2_append_action():
    payload = _load(f"next_comments_page2_{VIDEO_ID}.json")
    items, next_token = parse_comments(payload)

    assert len(items) == 20
    assert next_token and len(next_token) > 50
    for item in items:
        assert item["author"], item
        assert item["text"], item
    # page 2 must differ from page 1 (no pinned @YouTube comment)
    assert all(i["author"] != "@YouTube" for i in items)


def test_parse_comments_without_threads():
    items, next_token = parse_comments({"onResponseReceivedEndpoints": []})
    assert items == []
    assert next_token is None
