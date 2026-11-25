"""Verified guest image cache tests."""

import hashlib
from pathlib import Path

import pytest

from lab import images
from lab.host import ProvisionError

URL = "https://example.test/guest.qcow2"


def test_downloaded_image_is_verified_and_reused(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    content = b"guest image contents"
    expected = hashlib.sha256(content).hexdigest()
    downloads: list[list[str]] = []

    def download(args: list[str], **_kwargs: object) -> None:
        downloads.append(args)
        Path(args[args.index("--output") + 1]).write_bytes(content)

    monkeypatch.setattr(images, "run", download)
    image = images.fetch_image(URL, expected)
    assert image.read_bytes() == content
    assert images.fetch_image(URL, expected) == image
    assert len(downloads) == 1
    assert "--proto-redir" in downloads[0]


def test_bad_download_never_becomes_a_cached_image(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    expected = hashlib.sha256(b"expected").hexdigest()

    def download(args: list[str], **_kwargs: object) -> None:
        Path(args[args.index("--output") + 1]).write_bytes(b"corrupted")

    monkeypatch.setattr(images, "run", download)
    with pytest.raises(ProvisionError, match="checksum mismatch"):
        images.fetch_image(URL, expected)
    assert not list((tmp_path / "cache").iterdir())


def test_cached_image_is_reverified(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    expected = hashlib.sha256(b"expected").hexdigest()
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / f"guest-{expected}.img").write_bytes(b"corrupted")
    with pytest.raises(ProvisionError, match="checksum mismatch"):
        images.fetch_image(URL, expected)


def test_symlinked_cache_entry_is_refused(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    expected = hashlib.sha256(b"expected").hexdigest()
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / f"guest-{expected}.img").symlink_to(tmp_path / "outside")
    with pytest.raises(ProvisionError, match="symlink"):
        images.fetch_image(URL, expected)


@pytest.mark.parametrize(
    ("url", "sha256"),
    [
        ("http://example.test/image", "a" * 64),
        ("https://user:secret@example.test/image", "a" * 64),
        ("https://example.test/image?token=secret", "a" * 64),
        (URL, "../not-a-sha256"),
    ],
)
def test_invalid_image_metadata_is_rejected(url: str, sha256: str) -> None:
    with pytest.raises(ProvisionError):
        images.fetch_image(url, sha256)
