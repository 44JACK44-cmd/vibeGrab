"""The two stream-url sources must run at the same time.

`get_stream_urls` used to await the innertube request and then the Invidious
metadata call: both round trips sat in front of the first frame of every cold
play. A barrier makes the overlap deterministic (no sleeps, no timing
thresholds): if the sources ran serially the barrier would never fill.
"""

import threading

import pytest

from app.services import youtube_watch_service as watch

VIDEO_ID = "dQw4w9WgXcQ"


@pytest.fixture(autouse=True)
def _offline(monkeypatch):
    """No background warm-ups: they would hit the network from the tests."""
    watch.clear_cache()
    monkeypatch.setattr(watch, "_relay_warm_kick", lambda video_id: None)
    monkeypatch.setattr(watch, "_warm_anubis", lambda url: None)
    monkeypatch.setattr(watch, "_apply_invidious_metadata", lambda f, d: None)
    yield
    watch.clear_cache()


def _fields_with_video():
    fields = watch._stream_defaults()
    fields["video"] = "https://cdn/video.mp4"
    fields["audio"] = "https://cdn/audio.m4a"
    return fields


def test_stream_sources_run_in_parallel(monkeypatch):
    barrier = threading.Barrier(2, timeout=5)
    seen = {}

    def fake_innertube(video_id):
        barrier.wait()
        seen["innertube"] = video_id
        return {"picked": True}

    def fake_invidious(path):
        barrier.wait()
        seen["invidious"] = path
        return {}

    monkeypatch.setattr(watch, "_innertube_pick", fake_innertube)
    monkeypatch.setattr(watch, "_stream_from_innertube", lambda v, it: _fields_with_video())
    monkeypatch.setattr(watch, "_invidious_get", fake_invidious)

    result = watch.get_stream_urls(VIDEO_ID)

    assert result["video"] == "https://cdn/video.mp4"
    assert seen["innertube"] == VIDEO_ID
    assert VIDEO_ID in seen["invidious"]


def test_stream_urls_are_cached(monkeypatch):
    calls = []

    def fake_pick(video_id):
        calls.append(video_id)
        return {"picked": True}

    monkeypatch.setattr(watch, "_innertube_pick", fake_pick)
    monkeypatch.setattr(watch, "_invidious_get", lambda path: {})
    monkeypatch.setattr(watch, "_stream_from_innertube", lambda v, it: _fields_with_video())

    watch.get_stream_urls("cachetest01")
    watch.get_stream_urls("cachetest01")

    assert calls.count("cachetest01") == 1


def test_watch_error_mentions_both_sources(monkeypatch):
    monkeypatch.setattr(watch, "_innertube_pick", lambda video_id: None)

    def boom(path):
        raise RuntimeError("instance down")

    monkeypatch.setattr(watch, "_invidious_get", boom)

    with pytest.raises(watch.WatchError) as err:
        watch.get_stream_urls("allfail0001")
    assert "invidious: instance down" in str(err.value)
