"""Download and verify guest images before they are used by the lab."""

import hashlib
import re
import tempfile
from pathlib import Path
from urllib.parse import urlparse

import typer

from lab.config import cache_dir
from lab.host import ProvisionError
from lab.run import run


def _verify(path: Path, expected: str) -> None:
    digest = hashlib.sha256()
    with path.open("rb") as image:
        for chunk in iter(lambda: image.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != expected:
        raise ProvisionError(
            f"image checksum mismatch for {path}: expected {expected}, got {digest.hexdigest()}"
        )


def fetch_image(url: str, sha256: str) -> Path:
    """Return a checksum-verified cached image, downloading it if necessary."""
    expected = sha256.lower()
    if not re.fullmatch(r"[0-9a-f]{64}", expected):
        raise ProvisionError("guest image SHA-256 must contain exactly 64 hexadecimal characters")
    parsed = urlparse(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
    ):
        raise ProvisionError(
            "guest image URL must be an HTTPS URL without credentials, a query or a fragment"
        )

    cache = cache_dir()
    image = cache / f"guest-{expected}.img"
    if image.is_symlink():
        raise ProvisionError(f"refusing symlinked image cache entry: {image}")
    if image.exists():
        if not image.is_file():
            raise ProvisionError(f"image cache entry is not a regular file: {image}")
        _verify(image, expected)
        typer.echo(f"Using verified cached image: {image}")
        return image

    typer.echo(f"Downloading guest image: {url}")
    with tempfile.TemporaryDirectory(prefix=".guest-", dir=cache) as temporary:
        partial = Path(temporary) / "image.part"
        run(
            [
                "curl",
                "--fail",
                "--location",
                "--show-error",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--retry",
                "3",
                "--output",
                str(partial),
                url,
            ],
            description="download guest image",
            capture=False,
            timeout=3600,
        )
        _verify(partial, expected)
        try:
            image.hardlink_to(partial)
        except FileExistsError:
            raise ProvisionError(f"image cache entry appeared during download: {image}") from None
    typer.echo(f"Verified image cached: {image}")
    return image
