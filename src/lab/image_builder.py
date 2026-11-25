"""Experimental, local disk-image build stage; registry publishing is not yet implemented."""

import json
import re
import shlex
from datetime import UTC, datetime
from pathlib import PurePosixPath

import typer

from lab.cluster import Cluster
from lab.host import ProvisionError, assert_managed, ssh_options
from lab.images import fetch_image
from lab.run import CommandError, run
from lab.vms import Blueprint

VERSION = re.compile(r"[0-9]{8}T[0-9]{12}Z")
OWNER = "microsegmentation-iac-v2"
DISK_LAYOUT = "gpt-preserved-v1"
# The final 33 sectors of the 10 GiB disk are reserved for the backup GPT.
ROOT_END_SECTOR = str(10 * 1024**3 // 512 - 34)
UPDATE = (
    "export DEBIAN_FRONTEND=noninteractive; "
    "apt-get -o APT::Update::Error-Mode=any update && "
    "apt-get -y -o Dpkg::Options::=--force-confold upgrade --with-new-pkgs"
)


def _command(cluster: Cluster, args: list[str], description: str, timeout: int = 300) -> str:
    try:
        return cluster.rsh(shlex.join(args), description, timeout=timeout).stdout.strip()
    except CommandError as error:
        if error.completed and error.completed.stderr:
            detail = error.completed.stderr.strip()[-6000:]
            raise CommandError(f"{description} failed:\n{detail}", error.completed) from error
        raise


def _root(cluster: Cluster, blueprint: Blueprint) -> PurePosixPath:
    if blueprint.name != "ubuntu-server" or blueprint.os != "ubuntu-24.04":
        raise ProvisionError("experimental builder currently supports only ubuntu-server")
    assert_managed(cluster.vm)
    home = _command(cluster, ["printenv", "HOME"], "find image builder home")
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", home) or ".." in PurePosixPath(home).parts:
        raise ProvisionError("outer VM home directory is not a safe absolute path")
    return PurePosixPath(home) / ".local/share/microsegmentation-iac/image-builds" / blueprint.name


def _pointer(cluster: Cluster, root: PurePosixPath, name: str) -> str:
    cluster.rsh(
        f"test ! -L {shlex.quote(str(root / name))}",
        f"check image {name} pointer is not a symlink",
    )
    result = _command(cluster, ["cat", str(root / name)], f"read image {name} version")
    if not VERSION.fullmatch(result):
        raise ProvisionError(f"invalid {name} image version: {result!r}")
    return result


def _verify(cluster: Cluster, directory: PurePosixPath) -> str:
    cluster.rsh(
        f"test ! -L {shlex.quote(str(directory))} && "
        f"test ! -L {shlex.quote(str(directory / 'disk.qcow2'))} && "
        f"test ! -L {shlex.quote(str(directory / 'SHA256SUMS'))}",
        "check image paths are not symlinks",
    )
    expected = _command(cluster, ["cat", str(directory / "SHA256SUMS")], "read image checksum")
    match = re.fullmatch(r"([a-f0-9]{64})  disk\.qcow2", expected)
    if not match:
        raise ProvisionError("invalid built image checksum file")
    checksum = _command(
        cluster, ["sha256sum", str(directory / "disk.qcow2")], "hash built image", timeout=1200
    )
    digest = checksum.split()[0] if checksum.split() else ""
    if not re.fullmatch(r"[a-f0-9]{64}", digest) or digest != match.group(1):
        raise ProvisionError("built image checksum mismatch")
    return digest


def list_images(cluster: Cluster, blueprint: Blueprint) -> None:
    """List local experimental image versions."""
    root = _root(cluster, blueprint)
    entries = _command(
        cluster,
        ["find", str(root), "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-printf", "%f\n"],
        "list local image versions",
    )
    versions = sorted(name for name in entries.splitlines() if VERSION.fullmatch(name))
    if not versions:
        raise ProvisionError(f"no local images for {blueprint.name}; build a base image first")
    base = _pointer(cluster, root, "base")
    latest = _pointer(cluster, root, "latest")
    if base not in versions or latest not in versions:
        raise ProvisionError("image base/latest pointer refers to a missing version")
    for version in versions:
        aliases = ", ".join(
            name for name, value in (("base", base), ("latest", latest)) if version == value
        )
        typer.echo(f"{version}" + (f" ({aliases})" if aliases else ""))


def verify_image(cluster: Cluster, blueprint: Blueprint, selection: str) -> None:
    """Verify one local image version and its provenance manifest."""
    root = _root(cluster, blueprint)
    version = _pointer(cluster, root, selection) if selection in ("base", "latest") else selection
    if not VERSION.fullmatch(version):
        raise ProvisionError(f"invalid image version: {version!r}")
    digest = _verify_version(cluster, blueprint, root, version)
    typer.echo(f"Verified {blueprint.name}:{version} sha256:{digest}")


def _verify_version(
    cluster: Cluster, blueprint: Blueprint, root: PurePosixPath, version: str
) -> str:
    directory = root / version
    digest = _verify(cluster, directory)
    manifest_path = directory / "manifest.json"
    cluster.rsh(
        f"test ! -L {shlex.quote(str(manifest_path))}",
        "check image manifest is not a symlink",
    )
    raw = _command(cluster, ["cat", str(manifest_path)], "read image manifest")
    try:
        manifest = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ProvisionError(f"invalid image manifest: {error}") from None
    if (
        not isinstance(manifest, dict)
        or manifest.get("blueprint") != blueprint.name
        or manifest.get("version") != version
        or manifest.get("sha256") != digest
        or manifest.get("disk_layout") != DISK_LAYOUT
    ):
        raise ProvisionError("image manifest does not match the disk")
    return digest


def build(cluster: Cluster, blueprint: Blueprint, *, patch: bool) -> None:
    """Build a local test disk; never modifies an existing image or a VM."""
    root = _root(cluster, blueprint)
    version = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    target = root / version
    work = root / f".work-{version}"
    lock = root / ".build-lock"
    paths = [root, *list(root.parents)[:4]]
    checks = " && ".join(f"test ! -L {shlex.quote(str(path))}" for path in paths)
    marker = shlex.quote(str(root / ".managed-by"))
    directory = shlex.quote(str(root))
    cluster.rsh(
        f"{checks} && if test -d {directory}; then "
        f"if test -L {marker} || ! test -f {marker} || "
        f'! test "$(cat {marker})" = {OWNER}; then '
        "echo 'refusing unmarked image build directory' >&2; exit 1; fi; "
        f"else mkdir -p -m 700 -- {directory} && "
        f"printf '%s\\n' {OWNER} > {marker}; fi",
        "prepare image build directory without symlinks",
    )
    _command(cluster, ["mkdir", "-m", "700", str(lock)], "acquire image build lock")
    workspace_created = False
    uncertain = False
    try:
        _command(cluster, ["mkdir", "-m", "700", str(work)], "create image build workspace")
        workspace_created = True
        disk = work / "disk.qcow2"
        if patch:
            base = _pointer(cluster, root, "base")
            base_directory = root / base
            source_hash = _verify_version(cluster, blueprint, root, base)
            _command(
                cluster,
                [
                    "qemu-img",
                    "convert",
                    "-f",
                    "qcow2",
                    "-O",
                    "qcow2",
                    str(base_directory / "disk.qcow2"),
                    str(disk),
                ],
                "copy base image for patching",
                timeout=1800,
            )
        else:
            base = None
            source_hash = blueprint.image_sha256.lower()
            local_source = fetch_image(blueprint.image_url, source_hash)
            remote_source = work / "source.qcow2"
            run(
                [
                    "scp",
                    *ssh_options(cluster.vm),
                    str(local_source),
                    f"{cluster.vm.user}@{cluster.ip}:{remote_source}",
                ],
                description=f"copy verified {blueprint.name} image to builder",
                timeout=1800,
            )
            result = _command(
                cluster, ["sha256sum", str(remote_source)], "hash builder source image"
            )
            if not result.split() or result.split()[0] != source_hash:
                raise ProvisionError("image checksum mismatch after transfer to outer VM")
            _command(
                cluster,
                [
                    "qemu-img",
                    "convert",
                    "-f",
                    "qcow2",
                    "-O",
                    "qcow2",
                    str(remote_source),
                    str(disk),
                ],
                "copy verified Ubuntu source disk",
                timeout=1800,
            )
            _command(
                cluster, ["qemu-img", "resize", "-f", "qcow2", str(disk), "10G"], "grow base disk"
            )
            _command(
                cluster,
                [
                    "sudo",
                    "-n",
                    "env",
                    "LIBGUESTFS_BACKEND=direct",
                    "guestfish",
                    "--format=qcow2",
                    "-a",
                    str(disk),
                    "run",
                    ":",
                    "part-expand-gpt",
                    "/dev/sda",
                    ":",
                    "part-resize",
                    "/dev/sda",
                    "1",
                    ROOT_END_SECTOR,
                    ":",
                    "resize2fs",
                    "/dev/sda1",
                ],
                "grow Ubuntu root filesystem without renumbering partitions",
                timeout=1800,
            )
            _command(cluster, ["rm", "--", str(remote_source)], "remove temporary source disk")
        command = UPDATE
        if not patch:
            command += " && apt-get -y install qemu-guest-agent openssh-server"
        typer.echo(f"{blueprint.name}: updating isolated image; this may take several minutes.")
        _command(
            cluster,
            [
                "sudo",
                "-n",
                "env",
                "LIBGUESTFS_BACKEND=direct",
                "virt-customize",
                "--format",
                "qcow2",
                "-a",
                str(disk),
                "--run-command",
                command,
            ],
            "patch isolated Ubuntu image",
            timeout=3600,
        )
        _command(
            cluster,
            [
                "sudo",
                "-n",
                "env",
                "LIBGUESTFS_BACKEND=direct",
                "virt-sysprep",
                "--format",
                "qcow2",
                "-a",
                str(disk),
            ],
            "remove instance-specific image data",
            timeout=1200,
        )
        _command(
            cluster,
            ["qemu-img", "check", "-f", "qcow2", str(disk)],
            "check built disk",
            timeout=1200,
        )
        digest = _command(
            cluster, ["sha256sum", str(disk)], "hash built disk", timeout=1200
        ).split()[0]
        if not re.fullmatch(r"[a-f0-9]{64}", digest):
            raise ProvisionError("invalid built image checksum")
        metadata = {
            "blueprint": blueprint.name,
            "version": version,
            "sha256": digest,
            "source_sha256": source_hash,
            "base_version": base,
            "disk_layout": DISK_LAYOUT,
        }
        cluster.rsh(
            f"umask 077; cat > {shlex.quote(str(work / 'manifest.json'))}",
            "record image provenance",
            input_text=json.dumps(metadata, indent=2) + "\n",
        )
        cluster.rsh(
            f"umask 077; cat > {shlex.quote(str(work / 'SHA256SUMS'))}",
            "record built image checksum",
            input_text=f"{digest}  disk.qcow2\n",
        )
        _verify(cluster, work)
        _command(
            cluster,
            [
                "chmod",
                "a-w",
                str(disk),
                str(work / "manifest.json"),
                str(work / "SHA256SUMS"),
            ],
            "protect completed image files",
        )
        cluster.rsh(
            f"test ! -e {shlex.quote(str(target))} && "
            f"mv -T -- {shlex.quote(str(work))} {shlex.quote(str(target))}",
            "publish immutable local image version",
        )
        for pointer in ("base", "latest") if not patch else ("latest",):
            temporary_pointer = shlex.quote(str(lock / pointer))
            cluster.rsh(
                f"printf '%s\\n' {shlex.quote(version)} > {temporary_pointer}"
                f" && mv -T -- {temporary_pointer} "
                f"{shlex.quote(str(root / pointer))}",
                f"update image {pointer} pointer",
            )
        typer.echo(f"Built local test image {blueprint.name}:{version} sha256:{digest}")
        typer.echo("Not published to a registry or selectable by lab vm apply.")
    except CommandError as error:
        uncertain = error.completed is None or error.completed.returncode == 255
        raise
    except KeyboardInterrupt:
        uncertain = True
        raise
    finally:
        if uncertain:
            typer.secho(
                "Build outcome is unknown; inspect the outer VM before removing "
                f"{work} and {lock}.",
                err=True,
                fg=typer.colors.YELLOW,
            )
        else:
            cleanup = f"rm -rf -- {shlex.quote(str(work))} && " if workspace_created else ""
            cluster.rsh(
                f"{cleanup}rmdir -- {shlex.quote(str(lock))}",
                "clean image build workspace and release lock",
                timeout=300,
            )
