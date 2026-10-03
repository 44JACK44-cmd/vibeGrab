import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.extractor_service import (
    is_kwai_url,
    parse_kwai_page,
    _iso_to_seconds,
    _resolve_kwai_target,
)

FIXTURE_HTML = """
<html><head>
<meta data-n-head="ssr" property="og:title" data-hid="og:title">
<meta property="og:image" content="https://aws-br-pic.kwai.net/upic/2026/01/24/08/BMjAyNjAxMjQwODQ4MTNfMTUwMDAxNDU1MDE5OTQ1XzE1MDExMDI4NTA4NDg3NF8yXzM=_oscn2_Befd2f922b58f2b5f72e4cb3c375d043d.webp"/>
<meta property="og:description" content="BANDIDO ESTAVA ESPERANDO ELE NA SAIDA DO BANCO"/>
</head><body>
<script>window.__STATE__={"duration":"PT2M36S","width":720,"height":1280,
"author":"Topseriesfilmetv","audio":{"name":"Audio"}}</script>
<img src="https://aws-br-cdn.kwai.net/upic/2026/10/01/05/OTHERVIDEO_b_other.mp4"/>
<a href="https://aws-br-cdn.kwai.net/upic/2026/01/24/08/BMjAyNjAxMjQwODQ4MTNfMTUwMDAxNDU1MDE5OTQ1XzE1MDExMDI4NTA4NDg3NF8yXzM=_b_Bf1ce0ec42b4fe4482cd50678b3abd2d4.mp4?tag=1-123">play</a>
</body></html>
"""


def test_is_kwai_url_variants():
    assert is_kwai_url("https://www.kwai.com/@user/video/123") is True
    assert is_kwai_url("https://v.kwai.com/u/abc") is True
    assert is_kwai_url("https://k.kwai.com/p/AbC") is True
    assert is_kwai_url("https://v.kuaishou.com/1a23vvd1") is True
    assert is_kwai_url("https://kwai-video.com/p/fJSPUCEv") is True
    assert is_kwai_url("https://m.kwai.com/photo/1/2") is True
    assert is_kwai_url("https://www.youtube.com/watch?v=abc") is False
    assert is_kwai_url("not a url") is False


def test_resolve_kwai_target_from_redirect_query():
    final_url = (
        "https://kwai-share.onelink.me/doYv?pid=H5"
        "&af_sub1=%7B%22shareInfo%22%3A%7B%22target_url%22%3A%22"
        "https%3A%2F%2Fm.kwai.com%2Fphoto%2F150001293514308%2F5229392174934693014"
        "%3FuserId%3D150001293514308%22%7D%7D"
    )
    target = _resolve_kwai_target(final_url, "<html></html>")
    assert target is not None
    assert target.startswith("https://m.kwai.com/photo/150001293514308/")
    assert "userId=150001293514308" in target


def test_resolve_kwai_target_from_page_js():
    page = (
        "<script>var app_link = 'ikwai://work/5229392174934693014?"
        "target_url=https://m.kwai.com/photo/150001293514308/5229392174934693014"
        "?userId=150001293514308&photoId=5229392174934693014&short_key=fJSPUCEv';"
        "</script>"
    )
    target = _resolve_kwai_target("https://kwai-share.onelink.me/doYv", page)
    assert target is not None
    assert "m.kwai.com/photo/150001293514308/5229392174934693014" in target
    assert "short_key=fJSPUCEv" in target


def test_resolve_kwai_target_none_for_unrelated_page():
    assert _resolve_kwai_target("https://example.com/x", "<html>hi</html>") is None


def test_iso_duration():
    assert _iso_to_seconds("PT2M36S") == 156
    assert _iso_to_seconds("PT1H") == 3600
    assert _iso_to_seconds("PT45S") == 45
    assert _iso_to_seconds(None) is None
    assert _iso_to_seconds("garbage") is None


def test_parse_kwai_page_fixture():
    meta = parse_kwai_page(
        FIXTURE_HTML, "https://www.kwai.com/@topfilmeseseriesnatv/video/5240932700689736196"
    )
    assert meta["id"] == "5240932700689736196"
    assert "BANDIDO" in meta["title"]
    assert meta["duration"] == 156
    assert meta["height"] == 1280
    assert meta["uploader"] == "Topseriesfilmetv"
    assert meta["thumbnail"].startswith("https://aws-br-pic.kwai.net/")
    # main video (same id as og:image) must win over the recommendation
    assert "BMjAyNjAxMjQwODQ4MTNfMTUwMDAxNDU1" in meta["url"]
    assert meta["url"].endswith(".mp4?tag=1-123")


def test_parse_kwai_page_no_video_raises():
    try:
        parse_kwai_page("<html><body>nothing</body></html>", "https://www.kwai.com/x/video/1")
        assert False, "should raise"
    except Exception as e:
        assert "No video URL" in str(e)


def test_parse_kwai_fallback_title():
    html = FIXTURE_HTML.replace(
        'property="og:description" content="BANDIDO ESTAVA ESPERANDO ELE NA SAIDA DO BANCO"',
        'property="og:description" content=""',
    )
    meta = parse_kwai_page(html, "https://www.kwai.com/@someone/video/999")
    assert meta["title"] == "@Topseriesfilmetv on Kwai"
