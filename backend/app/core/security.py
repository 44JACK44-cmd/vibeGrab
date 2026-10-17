"""Request-level security: optional API key + in-memory rate limiting.

Both checks are enforced through a single FastAPI dependency
(`verify_request`) attached at the application level. Using a dependency
instead of a middleware avoids interfering with StreamingResponse and
BackgroundTasks, which the download/relay endpoints rely on.
"""
import hmac
import threading
import time

from fastapi import HTTPException, Request

from app.core.config import settings

# Endpoints that must stay reachable without auth/limits: the health probe
# (used by UptimeRobot) and the interactive docs.
OPEN_PATHS = frozenset(
    {
        "/",
        "/api/health",
        "/docs",
        "/redoc",
        "/openapi.json",
        "/docs/oauth2-redirect",
    }
)

# Hard cap on tracked clients so memory cannot grow without bound.
_MAX_TRACKED_CLIENTS = 50_000


class RateLimiter:
    """Simple fixed-window limiter keyed by client (in-memory, thread-safe)."""

    def __init__(self) -> None:
        self._hits: dict[str, tuple[float, int]] = {}
        self._lock = threading.Lock()

    def allow(
        self,
        key: str,
        limit: int,
        window: float,
        now: float | None = None,
    ) -> bool:
        """Return True if `key` is still under `limit` within `window`s.

        A non-positive `limit` disables limiting.
        """
        if limit <= 0:
            return True
        now = time.time() if now is None else now
        with self._lock:
            start, count = self._hits.get(key, (now, 0))
            if now - start >= window:
                start, count = now, 0
            count += 1
            self._hits[key] = (start, count)
            if len(self._hits) > _MAX_TRACKED_CLIENTS:
                self._prune(now - window)
            return count <= limit

    def reset(self) -> None:
        with self._lock:
            self._hits.clear()

    def _prune(self, cutoff: float) -> None:
        self._hits = {k: v for k, v in self._hits.items() if v[0] >= cutoff}


_limiter = RateLimiter()


def api_key_ok(provided: str | None) -> bool:
    """True when auth is disabled or the provided key matches (constant time)."""
    if not settings.API_KEY:
        return True
    return hmac.compare_digest(provided or "", settings.API_KEY)


def client_ip(request: Request) -> str:
    if request.client and request.client.host:
        return request.client.host
    return "unknown"


def verify_request(request: Request) -> None:
    """FastAPI dependency: enforce API key (if configured) and rate limit."""
    if request.method == "OPTIONS" or request.url.path in OPEN_PATHS:
        return

    if not api_key_ok(request.headers.get("x-api-key")):
        raise HTTPException(
            status_code=401,
            detail="Unauthorized",
            headers={"WWW-Authenticate": "X-API-Key"},
        )

    if not settings.RATE_LIMIT_ENABLED:
        return

    if not _limiter.allow(
        client_ip(request),
        limit=settings.RATE_LIMIT_PER_MINUTE,
        window=settings.RATE_LIMIT_WINDOW_SECONDS,
    ):
        raise HTTPException(
            status_code=429,
            detail="Too many requests",
            headers={"Retry-After": str(settings.RATE_LIMIT_WINDOW_SECONDS)},
        )
