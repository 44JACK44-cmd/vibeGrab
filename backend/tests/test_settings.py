import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.settings_service import AppSettings, load_settings, save_settings


def test_default_settings():
    s = AppSettings()
    assert s.max_concurrent_downloads >= 1
    assert s.max_file_size_mb > 0
    assert s.auto_open_after_download is False
    assert s.prefer_best_quality is True


def test_settings_roundtrip(tmp_path, monkeypatch):
    test_file = tmp_path / ".app_settings.json"
    monkeypatch.setattr(
        "app.services.settings_service._get_settings_path", lambda: test_file
    )
    original = AppSettings(max_concurrent_downloads=3, auto_open_after_download=True)
    save_settings(original)

    loaded = load_settings()
    assert loaded.max_concurrent_downloads == 3
    assert loaded.auto_open_after_download is True
    assert loaded.prefer_best_quality is True


def test_load_settings_missing_file(tmp_path, monkeypatch):
    monkeypatch.setattr(
        "app.services.settings_service._get_settings_path", lambda: tmp_path / "nonexistent.json"
    )
    loaded = load_settings()
    assert loaded.max_concurrent_downloads == 2
    assert loaded.auto_open_after_download is False
