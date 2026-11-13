"""Cluster install tests for the pure command builders."""

from lab import versions
from lab.cluster import (
    cilium_install_command,
    k3s_install_command,
    rewrite_kubeconfig,
)


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
