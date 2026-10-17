import sys
from pathlib import Path

import pytest
from fastapi import HTTPException
from starlette.requests import Request

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.core import security
from app.core.config import settings
from app.core.security import RateLimiter, api_key_ok, verify_request


@pytest.fixture(autouse=True)
def _reset_limiter():
    security._limiter.reset()
    yield
    security._limiter.reset()


def _make_request(
    path: str = "/api/analyze",
    method: str = "GET",
    headers: dict | None = None,
    client: tuple[str, int] | None = ("1.2.3.4", 1234),
) -> Request:
    raw_headers = [
        (k.lower().encode("latin-1"), v.encode("latin-1"))
        for k, v in (headers or {}).items()
    ]
    scope = {
        "type": "http",
        "method": method,
        "path": path,
        "headers": raw_headers,
        "query_string": b"",
        "scheme": "http",
        "server": ("testserver", 80),
        "client": client,
    }
    return Request(scope)


class TestRateLimiter:
    def test_allows_under_limit(self):
        rl = RateLimiter()
        assert rl.allow("k", limit=3, window=60, now=100.0)
        assert rl.allow("k", limit=3, window=60, now=100.0)
        assert rl.allow("k", limit=3, window=60, now=100.0)

    def test_blocks_over_limit(self):
        rl = RateLimiter()
        for _ in range(3):
            assert rl.allow("k", limit=3, window=60, now=100.0)
        assert rl.allow("k", limit=3, window=60, now=100.0) is False

    def test_window_resets(self):
        rl = RateLimiter()
        assert rl.allow("k", limit=1, window=60, now=100.0)
        assert rl.allow("k", limit=1, window=60, now=100.0) is False
        assert rl.allow("k", limit=1, window=60, now=161.0) is True

    def test_non_positive_limit_disables(self):
        rl = RateLimiter()
        assert all(rl.allow("k", limit=0, window=60, now=100.0) for _ in range(100))

    def test_keys_are_independent(self):
        rl = RateLimiter()
        assert rl.allow("a", limit=1, window=60, now=100.0)
        assert rl.allow("b", limit=1, window=60, now=100.0)


class TestApiKey:
    def test_disabled_when_unset(self, monkeypatch):
        monkeypatch.setattr(settings, "API_KEY", "")
        assert api_key_ok(None) is True
        assert api_key_ok("whatever") is True

    def test_matches_when_set(self, monkeypatch):
        monkeypatch.setattr(settings, "API_KEY", "secret")
        assert api_key_ok("secret") is True

    def test_rejects_wrong_or_missing(self, monkeypatch):
        monkeypatch.setattr(settings, "API_KEY", "secret")
        assert api_key_ok("nope") is False
        assert api_key_ok(None) is False
        assert api_key_ok("") is False


class TestVerifyRequest:
    def test_open_path_is_exempt(self, monkeypatch):
        monkeypatch.setattr(settings, "API_KEY", "secret")
        monkeypatch.setattr(settings, "RATE_LIMIT_ENABLED", True)
        monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 1)
        # /api/health needs no key and is not rate limited.
        verify_request(_make_request(path="/api/health"))

    def test_options_bypasses_checks(self, monkeypatch):
        monkeypatch.setattr(settings, "API_KEY", "secret")
        verify_request(_make_request(method="OPTIONS"))

    def test_requires_key_when_configured(self, monkeypatch):
        monkeypatch.setattr(settings, "API_KEY", "secret")
        with pytest.raises(HTTPException) as exc:
            verify_request(_make_request(path="/api/status"))
        assert exc.value.status_code == 401

    def test_accepts_correct_key(self, monkeypatch):
        monkeypatch.setattr(settings, "API_KEY", "secret")
        verify_request(
            _make_request(path="/api/status", headers={"X-API-Key": "secret"})
        )

    def test_rate_limit_returns_429(self, monkeypatch):
        monkeypatch.setattr(settings, "API_KEY", "")
        monkeypatch.setattr(settings, "RATE_LIMIT_ENABLED", True)
        monkeypatch.setattr(settings, "RATE_LIMIT_PER_MINUTE", 2)
        verify_request(_make_request(path="/api/status"))
        verify_request(_make_request(path="/api/status"))
        with pytest.raises(HTTPException) as exc:
            verify_request(_make_request(path="/api/status"))
        assert exc.value.status_code == 429

    def test_rate_limit_can_be_disabled(self, monkeypatch):
        monkeypatch.setattr(settings, "RATE_LIMIT_ENABLED", False)
        for _ in range(50):
            verify_request(_make_request(path="/api/status"))
