"""Safety checks for the experimental local disk builder."""

import json
import subprocess
from unittest.mock import Mock

import pytest

from lab import image_builder
from lab.host import ProvisionError
from lab.run import CommandError
from lab.vms import load_blueprint


def _cluster() -> Mock:
    cluster = Mock()
    cluster.vm.name = "outer"
    cluster.vm.user = "labadmin"
    cluster.ip = "192.0.2.1"
    return cluster


def test_rejects_unsupported_blueprints_before_touching_cluster() -> None:
    cluster = _cluster()
    with pytest.raises(ProvisionError, match="only ubuntu-server"):
        image_builder.build(cluster, load_blueprint("ubuntu-desktop"), patch=False)
    cluster.rsh.assert_not_called()


def test_does_not_remove_workspace_it_failed_to_create(monkeypatch: pytest.MonkeyPatch) -> None:
    cluster = _cluster()
    monkeypatch.setattr(image_builder, "assert_managed", lambda _vm: None)

    def rsh(command: str, description: str, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        if description == "find image builder home":
            return subprocess.CompletedProcess([], 0, stdout="/home/labadmin")
        if description == "create image build workspace":
            raise CommandError("workspace already exists", subprocess.CompletedProcess([], 1))
        return subprocess.CompletedProcess([], 0, stdout="")

    cluster.rsh.side_effect = rsh
    with pytest.raises(CommandError, match="workspace already exists"):
        image_builder.build(cluster, load_blueprint("ubuntu-server"), patch=True)
    cleanup = cluster.rsh.call_args.args[0]
    assert cleanup.startswith("rmdir -- ")
    assert "rm -rf" not in cleanup


def test_patch_refuses_modified_base_without_publishing(monkeypatch: pytest.MonkeyPatch) -> None:
    cluster = _cluster()
    monkeypatch.setattr(image_builder, "assert_managed", lambda _vm: None)

    def rsh(command: str, description: str, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        output = {
            "find image builder home": "/home/labadmin",
            "read image base version": "20261125T120000000000Z",
            "read image checksum": f"{'a' * 64}  disk.qcow2",
            "hash built image": f"{'b' * 64}  disk.qcow2",
        }.get(description, "")
        return subprocess.CompletedProcess([], 0, stdout=output)

    cluster.rsh.side_effect = rsh
    with pytest.raises(ProvisionError, match="checksum mismatch"):
        image_builder.build(cluster, load_blueprint("ubuntu-server"), patch=True)
    descriptions = [call.args[1] for call in cluster.rsh.call_args_list]
    assert "copy base image for patching" not in descriptions
    assert "update image latest pointer" not in descriptions
    assert descriptions[-1] == "clean image build workspace and release lock"


def test_base_refuses_corrupted_transfer(monkeypatch: pytest.MonkeyPatch, tmp_path: object) -> None:
    cluster = _cluster()
    monkeypatch.setattr(image_builder, "assert_managed", lambda _vm: None)
    monkeypatch.setattr(image_builder, "fetch_image", lambda *_args: tmp_path)
    monkeypatch.setattr(image_builder, "ssh_options", lambda _vm: [])
    monkeypatch.setattr(image_builder, "run", Mock())

    def rsh(command: str, description: str, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        output = {
            "find image builder home": "/home/labadmin",
            "hash builder source image": f"{'b' * 64}  source.qcow2",
        }.get(description, "")
        return subprocess.CompletedProcess([], 0, stdout=output)

    cluster.rsh.side_effect = rsh
    with pytest.raises(ProvisionError, match="checksum mismatch after transfer"):
        image_builder.build(cluster, load_blueprint("ubuntu-server"), patch=False)
    descriptions = [call.args[1] for call in cluster.rsh.call_args_list]
    assert "grow Ubuntu root filesystem without renumbering partitions" not in descriptions
    assert "update image latest pointer" not in descriptions


def test_base_resize_keeps_gpt_partition_numbers(monkeypatch: pytest.MonkeyPatch) -> None:
    cluster = _cluster()
    blueprint = load_blueprint("ubuntu-server")
    monkeypatch.setattr(image_builder, "assert_managed", lambda _vm: None)
    monkeypatch.setattr(image_builder, "fetch_image", lambda *_args: "source.qcow2")
    monkeypatch.setattr(image_builder, "ssh_options", lambda _vm: [])
    monkeypatch.setattr(image_builder, "run", Mock())

    def rsh(command: str, description: str, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        if description == "grow Ubuntu root filesystem without renumbering partitions":
            raise CommandError("stop after resize", subprocess.CompletedProcess([], 1))
        output = {
            "find image builder home": "/home/labadmin",
            "hash builder source image": f"{blueprint.image_sha256}  source.qcow2",
        }.get(description, "")
        return subprocess.CompletedProcess([], 0, stdout=output)

    cluster.rsh.side_effect = rsh
    with pytest.raises(CommandError, match="stop after resize"):
        image_builder.build(cluster, blueprint, patch=False)
    resize = next(
        call.args[0]
        for call in cluster.rsh.call_args_list
        if call.args[1] == "grow Ubuntu root filesystem without renumbering partitions"
    )
    assert "guestfish" in resize
    assert "part-expand-gpt /dev/sda" in resize
    assert f"part-resize /dev/sda 1 {image_builder.ROOT_END_SECTOR}" in resize


def test_unknown_remote_outcome_keeps_lock_and_workspace(monkeypatch: pytest.MonkeyPatch) -> None:
    cluster = _cluster()
    monkeypatch.setattr(image_builder, "assert_managed", lambda _vm: None)

    def rsh(command: str, description: str, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        if description == "find image builder home":
            return subprocess.CompletedProcess([], 0, stdout="/home/labadmin")
        if description == "read image base version":
            raise CommandError("SSH timed out")
        return subprocess.CompletedProcess([], 0, stdout="")

    cluster.rsh.side_effect = rsh
    with pytest.raises(CommandError, match="timed out"):
        image_builder.build(cluster, load_blueprint("ubuntu-server"), patch=True)
    descriptions = [call.args[1] for call in cluster.rsh.call_args_list]
    assert "clean image build workspace and release lock" not in descriptions


def test_verify_rejects_mismatched_manifest(monkeypatch: pytest.MonkeyPatch) -> None:
    cluster = _cluster()
    monkeypatch.setattr(image_builder, "assert_managed", lambda _vm: None)
    version = "20261125T120000000000Z"
    digest = "a" * 64

    def rsh(command: str, description: str, **_kwargs: object) -> subprocess.CompletedProcess[str]:
        output = {
            "find image builder home": "/home/labadmin",
            "read image checksum": f"{digest}  disk.qcow2",
            "hash built image": f"{digest}  disk.qcow2",
            "read image manifest": json.dumps(
                {"blueprint": "ubuntu-server", "version": version, "sha256": "b" * 64}
            ),
        }.get(description, "")
        return subprocess.CompletedProcess([], 0, stdout=output)

    cluster.rsh.side_effect = rsh
    with pytest.raises(ProvisionError, match="manifest does not match"):
        image_builder.verify_image(cluster, load_blueprint("ubuntu-server"), version)


def test_verify_rejects_invalid_version_before_reading_image(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    cluster = _cluster()
    monkeypatch.setattr(image_builder, "assert_managed", lambda _vm: None)
    cluster.rsh.return_value.stdout = "/home/labadmin"
    with pytest.raises(ProvisionError, match="invalid image version"):
        image_builder.verify_image(cluster, load_blueprint("ubuntu-server"), "../outside")
    assert len(cluster.rsh.call_args_list) == 1
