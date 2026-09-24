import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.services.library_service import _is_safe_filename, get_file_path, delete_library_file


class TestIsSafeFilename:
    def test_normal_filename(self):
        assert _is_safe_filename("video.mp4") is True

    def test_normal_with_spaces(self):
        assert _is_safe_filename("my video.mp4") is True

    def test_dotfile(self):
        assert _is_safe_filename(".metadata.json") is False

    def test_parent_traversal_unix(self):
        assert _is_safe_filename("../etc/passwd") is False

    def test_parent_traversal_double(self):
        assert _is_safe_filename("../../etc/passwd") is False

    def test_parent_traversal_windows(self):
        assert _is_safe_filename("..\\windows\\system32") is False

    def test_slash_in_name(self):
        assert _is_safe_filename("subdir/file.mp4") is False

    def test_backslash_in_name(self):
        assert _is_safe_filename("subdir\\file.mp4") is False

    def test_dot_dot_only(self):
        assert _is_safe_filename("..") is False

    def test_empty_string(self):
        assert _is_safe_filename("") is True

    def test_whitespace_attack(self):
        assert _is_safe_filename("../../../etc/shadow") is False


class TestGetFilePath:
    def test_nonexistent_file(self):
        result = get_file_path("nonexistent_file_xyz.mp4")
        assert result is None

    def test_traversal_blocked(self):
        result = get_file_path("../../../etc/passwd")
        assert result is None

    def test_dotfile_blocked(self):
        result = get_file_path(".env")
        assert result is None


class TestDeleteLibraryFile:
    def test_delete_nonexistent(self):
        result = delete_library_file("nonexistent_xyz.mp4")
        assert result.success is False

    def test_delete_traversal_blocked(self):
        result = delete_library_file("../../../etc/passwd")
        assert result.success is False
        assert "Invalid" in result.message
