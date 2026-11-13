"""Outer-VM provisioning tests for the pure/renderable parts."""

from pathlib import Path

from lab.config import OuterVM
from lab.host import render_user_data, virt_install_args

VM = OuterVM(
    name="lab2-test",
    os="ubuntu-24.04",
    vcpus=8,
    memory_gib=32,
    disk_gib=150,
    network="default",
    user="labadmin",
)


def test_user_data_enforces_key_only_ssh_and_sudo() -> None:
    user_data = render_user_data(VM, "ssh-ed25519 AAAA test", "$6$hash")
    assert "allow-pw: false" in user_data
    assert "- ssh-ed25519 AAAA test" in user_data
    assert "hostname: lab2-test" in user_data
    assert "labadmin ALL=(ALL) NOPASSWD:ALL" in user_data
    assert "qemu-guest-agent" in user_data


def test_virt_install_args_carry_sizing_and_ownership_marker() -> None:
    args = virt_install_args(VM, Path("/cache/u.iso"), Path("/cache/seed.iso"))
    joined = " ".join(args)
    assert "--memory 32768" in joined
    assert "--vcpus 8" in joined
    assert "pool=default,size=150,format=qcow2,bus=virtio" in joined
    assert "title=microsegmentation-iac-v2-lab2-test" in joined
    assert "--noautoconsole" in joined
