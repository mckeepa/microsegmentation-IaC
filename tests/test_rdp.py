"""RDP configuration and tunnel behavior."""

import subprocess
from pathlib import Path
from unittest.mock import Mock

import pytest

from lab import access
from lab.config import ConfigError, RDPConfig, Size, VMDef, load_config
from lab.host import ProvisionError


def desktop(name: str, port: int) -> VMDef:
    return VMDef(
        name=name,
        blueprint="rocky-desktop",
        size=Size(vcpus=4, memory_gib=6, disk_gib=30),
        segment="desktop",
        ports=(22,),
        run=False,
        rdp=RDPConfig(local_port=port, user="desktop"),
    )


def test_all_reports_stopped_and_continues(monkeypatch: pytest.MonkeyPatch) -> None:
    running, second, stopped = (
        desktop("running", 13389),
        desktop("second", 13390),
        desktop("stopped", 13391),
    )
    cluster = Mock()
    monkeypatch.setattr(
        access,
        "_rdp_vmi_addresses",
        lambda _: {("desktop", "running"): "10.0.0.1", ("desktop", "second"): "10.0.0.2"},
    )
    tunnel = Mock()
    monkeypatch.setattr(access, "open_rdp_tunnel", tunnel)
    assert access.open_rdp_tunnels(cluster, (running, second, stopped)) == 1
    assert tunnel.call_count == 2
    tunnel.assert_any_call(cluster, running, "10.0.0.1")
    tunnel.assert_any_call(cluster, second, "10.0.0.2")


def test_tunnel_uses_guest_loopback_and_requested_local_port(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    cluster = Mock()
    cluster.ip = "192.0.2.1"
    cluster.vm.name = "outer"
    cluster.vm.user = "labadmin"
    execute = Mock(return_value=subprocess.CompletedProcess([], 0))
    monkeypatch.setattr(access, "run", execute)
    access.open_rdp_tunnel(cluster, desktop("desk", 13389), "10.0.0.1")
    argv = execute.call_args.args[0]
    assert "127.0.0.1:13389:127.0.0.1:3389" in argv
    assert "-f" in argv
    assert "ExitOnForwardFailure=yes" in argv


def test_existing_control_socket_failure_is_not_treated_as_success(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    cluster = Mock()
    cluster.ip = "192.0.2.1"
    cluster.vm.name = "outer"
    cluster.vm.user = "labadmin"
    path = tmp_path / "secrets"
    path.mkdir()
    import hashlib

    digest = hashlib.sha256(b"desktop/desk/10.0.0.1/13389").hexdigest()[:16]
    (path / f"rdp-{digest}").symlink_to(tmp_path / "other")
    with pytest.raises(ProvisionError, match="symlink"):
        access.open_rdp_tunnel(cluster, desktop("desk", 13389), "10.0.0.1")


def test_rdp_duplicate_ports_are_rejected(tmp_path: Path) -> None:
    path = tmp_path / "lab.yaml"
    path.write_text(
        "outer_vm: {name: outer, vcpus: 8, memory_gib: 32, disk_gib: 150}\n"
        "vms:\n"
        "  - {name: a, blueprint: rocky-desktop, segment: a, ports: [22], "
        "size: {vcpus: 1, memory_gib: 1, disk_gib: 10}, "
        "rdp: {local_port: 13389, user: desktop}}\n"
        "  - {name: b, blueprint: rocky-desktop, segment: b, ports: [22], "
        "size: {vcpus: 1, memory_gib: 1, disk_gib: 10}, "
        "rdp: {local_port: 13389, user: desktop}}\n"
    )
    with pytest.raises(ConfigError, match="unique"):
        load_config(path)
