"""The extractor asks every player client at once and keeps the richest answer.

The old order (android first) returned a single 360p muxed stream and no audio
track, so the download sheet had nothing to offer. These tests pin the
selection rules without spawning yt-dlp.
"""

import json

import pytest

from app.services import extractor_service as ex


class _FakeProc:
    """Minimal subprocess.Popen stand-in for the extractor coordinator."""

    def __init__(self, stdout="", stderr="", returncode=0, delay=0.0, error=None):
        self.stdout = stdout
        self.stderr = stderr
        self.returncode = returncode
        self.delay = delay
        self.error = error
        self.killed = False
        self._done = False

    def communicate(self, timeout=None):
        if self.delay:
            import time

            time.sleep(self.delay)
        self._done = True
        if self.error:
            raise self.error
        return self.stdout, self.stderr

    def poll(self):
        return 0 if self._done else None

    def kill(self):
        self.killed = True
        self._done = True

    def wait(self, timeout=None):
        self._done = True
        return 0


def _payload(heights, audio_bitrates=()):
    formats = [
        {"url": f"https://cdn/{h}.mp4", "height": h, "vcodec": "avc1", "acodec": "none"}
        for h in heights
    ]
    formats += [
        {"url": f"https://cdn/{b}.m4a", "abr": b, "vcodec": "none", "acodec": "mp4a"}
        for b in audio_bitrates
    ]
    return json.dumps({"formats": formats, "title": "t"})


RICH = _payload([1080, 720, 360], audio_bitrates=[128])
POOR = _payload([360])


@pytest.fixture(autouse=True)
def _clean_cache():
    ex._cache.clear()
    yield
    ex._cache.clear()


def test_richness_prefers_audio_tracks_and_heights():
    rich = json.loads(RICH)
    poor = json.loads(POOR)
    assert ex._richness(rich) > ex._richness(poor)


def test_youtube_keeps_the_rich_answer_even_when_android_answers_first(monkeypatch):
    calls = []

    def fake_spawn(url, client):
        calls.append(client)
        if client == "android":
            # Answers sooner, but with the poor ladder.
            return _FakeProc(stdout=POOR, delay=0.01)
        return _FakeProc(stdout=RICH, delay=0.15)

    monkeypatch.setattr(ex, "_spawn_extract", fake_spawn)

    data = ex._extract_youtube("https://www.youtube.com/watch?v=x")

    assert data["formats"] == json.loads(RICH)["formats"]
    # One run per client: the tv/web ones by name and the plain default (None).
    assert sorted(c for c in calls if c) == ["android", "tv_embedded"]
    assert None in calls


def test_youtube_falls_back_to_the_poor_answer_when_nothing_else_works(monkeypatch):
    def fake_spawn(url, client):
        if client == "android":
            return _FakeProc(stdout=POOR, delay=0.01)
        return _FakeProc(stderr="The page needs to be reloaded", returncode=1)

    monkeypatch.setattr(ex, "_spawn_extract", fake_spawn)

    data = ex._extract_youtube("https://www.youtube.com/watch?v=x")

    assert data["formats"] == json.loads(POOR)["formats"]


def test_youtube_raises_with_the_client_errors_when_everything_fails(monkeypatch):
    def fake_spawn(url, client):
        return _FakeProc(stderr=f"{client} rejected", returncode=1)

    monkeypatch.setattr(ex, "_spawn_extract", fake_spawn)

    with pytest.raises(ex.ExtractionError) as err:
        ex._extract_youtube("https://www.youtube.com/watch?v=x")
    assert "rejected" in str(err.value)


def test_extract_info_reuses_a_recent_answer(monkeypatch):
    runs = []

    def fake_extract(url):
        runs.append(url)
        return {"id": "1"}

    monkeypatch.setattr(ex, "_extract_youtube", fake_extract)

    url = "https://www.youtube.com/watch?v=cache-me"
    assert ex.extract_info(url) == {"id": "1"}
    assert ex.extract_info(url) == {"id": "1"}
    assert runs == [url]


def test_extract_info_uses_one_run_for_other_providers(monkeypatch):
    calls = []

    def fake_single(url):
        calls.append(url)
        return {"id": "tt"}

    monkeypatch.setattr(ex, "_extract_single", fake_single)

    assert ex.extract_info("https://www.tiktok.com/@a/video/1") == {"id": "tt"}
    assert calls == ["https://www.tiktok.com/@a/video/1"]


def test_cache_expires(monkeypatch):
    runs = []

    def fake_extract(url):
        runs.append(url)
        return {"id": str(len(runs))}

    monkeypatch.setattr(ex, "_extract_youtube", fake_extract)
    monkeypatch.setattr(ex, "_CACHE_TTL", 0.0)

    url = "https://www.youtube.com/watch?v=fresh"
    ex.extract_info(url)
    ex.extract_info(url)
    assert len(runs) == 2


def test_youtube_host_detection():
    assert ex._is_youtube("https://youtu.be/abc")
    assert ex._is_youtube("https://m.youtube.com/watch?v=abc")
    assert not ex._is_youtube("https://www.tiktok.com/@a/video/1")
