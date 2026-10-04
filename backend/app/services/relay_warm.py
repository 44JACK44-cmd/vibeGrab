"""Pre-started ffmpeg merges buffered in memory.

A cold merge takes ~10s to produce its first byte but ExoPlayer gives up
after 8s. The stream-url endpoint starts the merge while the user is still
on the video card, so /relay serves the first bytes instantly.

Retains up to _CAP bytes from the start of the stream so leaving and
re-entering the player replays from 0. Longer videos switch to a live
"tail" read for the active viewer; the entry is dropped when they leave so
the next open starts a fresh merge.
"""
from __future__ import annotations

import itertools
import subprocess
import threading
import time

from app.core.config import settings
from app.core.logging import logger
from app.services.anubis_client import ANTUBIS_UA, cookie_header

_CAP = 48 * 1024 * 1024   # bytes kept from the start (replay window)
_AHEAD = 8 * 1024 * 1024  # unread slack allowed while someone watches
_PREBUF = 1 * 1024 * 1024  # buffer built while nobody watches
_TTL = 120.0              # idle entries die after this
_MAX = 2                  # concurrent warm merges

_lock = threading.Lock()
_entries: dict[str, dict] = {}
_cids = itertools.count(1)
_last_err: dict[str, str] = {}


def build_proc(sources: dict) -> subprocess.Popen:
    """ffmpeg merging video+audio into a progressive mp4 on stdout."""
    video = sources.get("video") or ""
    ck = None
    if ".f5.si" in video:
        try:
            ck = cookie_header(video)
        except Exception as e:  # noqa: BLE001
            logger.info(f"relay cookie skipped: {e}")
    hdr_args: list[str] = []
    if ck:
        hdr = f"Cookie: {ck}\r\nReferer: https://invidious.f5.si/\r\n"
        hdr_args = ["-headers", hdr]
    ua = ANTUBIS_UA
    return subprocess.Popen(
        [
            settings.FFMPEG_PATH,
            "-hide_banner",
            "-loglevel", "error",
            "-probesize", "1048576",
            "-analyzeduration", "1000000",
            "-user_agent", ua,
            *hdr_args,
            "-i", video,
            "-user_agent", ua,
            *hdr_args,
            "-i", sources["audio"],
            "-c", "copy",
            "-f", "mp4",
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "pipe:1",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )


def _kill(entry: dict) -> None:
    with entry["cv"]:
        entry["stop"] = True
        entry["done"] = True
        entry["cv"].notify_all()
    proc = entry.get("proc")
    if proc is not None and proc.poll() is None:
        try:
            proc.kill()
        except Exception:  # noqa: BLE001
            pass


def _drop(vid: str, entry: dict) -> None:
    with _lock:
        if _entries.get(vid) is entry:
            del _entries[vid]
    _kill(entry)


def _cleanup_locked(now: float) -> None:
    for vid, e in list(_entries.items()):
        to_kill = False
        with e["cv"]:
            idle = e["consumers"] == {} and not e["tail_owner"]
            if idle and now - e["ts"] > _TTL:
                del _entries[vid]
                e["stop"] = True
                e["done"] = True
                e["cv"].notify_all()
                to_kill = True
        if to_kill:
            _kill(e)


def start(vid: str, sources: dict) -> None:
    """Begin merging in the background (idempotent per video id)."""
    if not sources.get("video") or not sources.get("audio"):
        return
    with _lock:
        _cleanup_locked(time.time())
        if vid in _entries:
            return
        if len(_entries) >= _MAX:
            oldest = min(_entries.items(), key=lambda kv: kv[1]["ts"])
            del _entries[oldest[0]]
            _kill(oldest[1])
        entry = {
            "cv": threading.Condition(),
            "chunks": [],
            "held": 0,
            "size": 0,
            "consumers": {},
            "tail_owner": None,
            "frozen": False,
            "done": False,
            "stop": False,
            "proc": None,
            "ts": time.time(),
        }
        _entries[vid] = entry
    threading.Thread(target=_worker, args=(vid, sources, entry), daemon=True).start()


def _worker(vid: str, sources: dict, entry: dict) -> None:
    try:
        proc = build_proc(sources)
    except Exception as e:  # noqa: BLE001
        logger.error(f"warm relay spawn failed for {vid}: {e}")
        _last_err[vid] = f"spawn: {e}"[:200]
        _drop(vid, entry)
        return
    entry["proc"] = proc

    def _drain() -> None:
        try:
            while proc.stderr.read(4096):
                pass
        except Exception:  # noqa: BLE001
            pass

    threading.Thread(target=_drain, daemon=True).start()
    stall = threading.Timer(60.0, proc.kill)
    stall.start()
    try:
        while True:
            cv = entry["cv"]
            with cv:
                while not entry["stop"]:
                    if entry["held"] >= _CAP:
                        entry["frozen"] = True
                        cv.notify_all()
                        cv.wait(timeout=1.0)
                        continue
                    if entry["consumers"]:
                        minpos = min(entry["consumers"].values())
                        if entry["size"] - minpos >= _AHEAD:
                            cv.wait(timeout=1.0)
                            continue
                    elif entry["held"] >= _PREBUF:
                        cv.wait(timeout=1.0)
                        continue
                    break
                if entry["stop"]:
                    return
            chunk = proc.stdout.read1(65536)
            if not chunk:
                break
            stall.cancel()
            with entry["cv"]:
                entry["chunks"].append(chunk)
                entry["held"] += len(chunk)
                entry["size"] += len(chunk)
                entry["ts"] = time.time()
                entry["cv"].notify_all()
    except Exception as e:  # noqa: BLE001
        logger.error(f"warm relay worker failed for {vid}: {e}")
        _last_err[vid] = f"worker: {e}"[:200]
    finally:
        stall.cancel()
        with entry["cv"]:
            entry["done"] = True
            entry["cv"].notify_all()
        if proc.poll() is None:
            proc.kill()
        try:
            proc.wait(timeout=5)
        except Exception:  # noqa: BLE001
            pass


def wait_first(vid: str, timeout: float = 8.0) -> bool:
    entry = _entries.get(vid)
    if entry is None:
        return False
    end = time.time() + timeout
    with entry["cv"]:
        while not entry["chunks"] and not entry["done"] and not entry["stop"]:
            remaining = end - time.time()
            if remaining <= 0:
                return False
            entry["cv"].wait(timeout=remaining)
        return bool(entry["chunks"])


def stream(vid: str):
    """Iterator over the merge output, or None if no warm entry exists."""
    entry = _entries.get(vid)
    if entry is None:
        return None
    cid = next(_cids)
    cv = entry["cv"]
    with cv:
        entry["consumers"][cid] = 0
        entry["ts"] = time.time()
        cv.notify_all()

    def _gen():
        i = 0
        pos = 0
        tail = False
        try:
            while True:
                with cv:
                    while (
                        i >= len(entry["chunks"])
                        and not entry["done"]
                        and not entry["stop"]
                        and not tail
                    ):
                        if (
                            entry["frozen"]
                            and entry["tail_owner"] in (None, cid)
                        ):
                            entry["tail_owner"] = cid
                            entry["consumers"][cid] = entry["size"]
                            tail = True
                            break
                        entry["cv"].wait(timeout=1.0)
                    if tail:
                        pass
                    elif i < len(entry["chunks"]):
                        chunk = entry["chunks"][i]
                        i += 1
                        pos += len(chunk)
                        entry["consumers"][cid] = pos
                        entry["ts"] = time.time()
                        cv.notify_all()
                    else:
                        return
                if tail:
                    break
                yield chunk
            proc = entry.get("proc")
            stdout = proc.stdout if proc else None
            if stdout is None:
                return
            while True:
                chunk = stdout.read1(65536)
                if not chunk:
                    break
                yield chunk
        finally:
            with cv:
                entry["consumers"].pop(cid, None)
                if entry.get("tail_owner") == cid:
                    entry["tail_owner"] = None
                cv.notify_all()
            if tail:
                # Viewer is gone; drop so the next open merges fresh.
                _drop(vid, entry)

    return _gen()
