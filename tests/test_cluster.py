"""Cluster install tests for the pure command builders."""

from unittest.mock import Mock

import pytest

from lab import cluster as cluster_module
from lab import host, versions
from lab.cluster import (
    cilium_install_command,
    k3s_install_command,
    rewrite_kubeconfig,
)
from lab.config import OuterVM

OUTER = OuterVM("outer", "ubuntu-24.04", 8, 32, 150, "default", "labadmin")


def test_k3s_install_disables_flannel_and_policy_controller() -> None:
    command = k3s_install_command()
    assert f"INSTALL_K3S_VERSION='{versions.K3S}'" in command
    assert "--flannel-backend=none" in command
    assert "--disable-network-policy" in command


def test_cilium_install_pins_version_and_matches_k3s_cidr() -> None:
    command = cilium_install_command()
    assert f"--version {versions.CILIUM}" in command
    assert versions.K3S_POD_CIDR in command
    assert "KUBECONFIG=/etc/rancher/k3s/k3s.yaml" in command


def test_kubeconfig_rewritten_to_vm_address() -> None:
    original = "server: https://127.0.0.1:6443\n"
    assert rewrite_kubeconfig(original, "192.168.122.57") == (
        "server: https://192.168.122.57:6443\n"
    )


@pytest.fixture
def status_cluster(monkeypatch: pytest.MonkeyPatch) -> Mock:
    monkeypatch.setattr(host, "domain_exists", lambda _name: True)
    monkeypatch.setattr(host, "domain_title", lambda _name: OUTER.managed_title)
    monkeypatch.setattr(host, "domain_state", lambda _name: "running")
    monkeypatch.setattr(cluster_module, "discover_ip", lambda _name: "192.0.2.1")
    cluster = Mock()
    cluster._check.return_value = True
    monkeypatch.setattr(cluster_module, "Cluster", lambda *_args, **_kwargs: cluster)
    return cluster


def test_status_checks_tools_without_installing(status_cluster: Mock) -> None:
    assert cluster_module.status(OUTER) == 0
    status_cluster.rsh.assert_not_called()
    assert any("virt-customize" in call.args[0] for call in status_cluster._check.call_args_list)


def test_status_installs_only_on_request(status_cluster: Mock) -> None:
    assert cluster_module.status(OUTER, install_image_tools=True) == 0
    commands = [call.args[0] for call in status_cluster.rsh.call_args_list]
    assert commands[0] == "sudo -n apt-get update"
    assert (
        "install -y --no-install-recommends libguestfs-tools qemu-utils isc-dhcp-client"
        in commands[1]
    )


def test_missing_optional_tools_warns_without_failing_lab(
    status_cluster: Mock, capsys: pytest.CaptureFixture[str]
) -> None:
    status_cluster._check.side_effect = lambda command, _description: (
        "virt-customize" not in command
    )
    assert cluster_module.status(OUTER) == 0
    assert "status --install-image-tools" in capsys.readouterr().out
    assert cluster_module.status(OUTER, install_image_tools=True) == 1
