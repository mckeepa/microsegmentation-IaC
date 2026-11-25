"""VM reconciliation tests: blueprints, manifests, and guest access commands."""

import subprocess

import pytest
import yaml

from lab.access import guest_ssh_command
from lab.config import OuterVM, Size, VMDef
from lab.host import ProvisionError
from lab.vms import load_blueprint, render_guest_user_data, vm_manifest

WEB = VMDef(
    name="web-01",
    blueprint="ubuntu-server",
    size=Size(vcpus=2, memory_gib=2, disk_gib=10),
    segment="web",
    ports=(22, 8080),
    run=True,
)
OUTER = OuterVM(
    name="outer",
    os="ubuntu-24.04",
    vcpus=8,
    memory_gib=32,
    disk_gib=150,
    network="default",
    user="labadmin",
)


def test_repo_blueprints_load_with_pinned_images() -> None:
    for name in ("ubuntu-server", "rocky-server", "ubuntu-desktop"):
        blueprint = load_blueprint(name)
        assert blueprint.image_url.startswith("https://")
        assert "latest" not in blueprint.image_url
        assert len(blueprint.image_sha256) == 64


def test_unknown_blueprint_lists_available() -> None:
    with pytest.raises(ProvisionError, match="available"):
        load_blueprint("no-such-blueprint")


def test_guest_user_data_injects_key_and_disables_passwords() -> None:
    blueprint = load_blueprint("ubuntu-server")
    user_data = render_guest_user_data(blueprint, "web-01", "ssh-ed25519 AAAA key")
    assert "hostname: web-01" in user_data
    assert "- ssh-ed25519 AAAA key" in user_data
    assert "ssh_pwauth: false" in user_data
    assert "lock_passwd: true" in user_data


def test_ubuntu_desktop_cloud_init_renders_and_configures_rdp() -> None:
    blueprint = load_blueprint("ubuntu-desktop")
    rendered = render_guest_user_data(blueprint, "ubuntu-desktop", "ssh-ed25519 AAAA key")
    config = yaml.safe_load(rendered)
    assert config["hostname"] == "ubuntu-desktop"
    assert config["users"][0]["ssh_authorized_keys"] == ["ssh-ed25519 AAAA key"]
    assert config["users"][1]["name"] == "desktop"
    assert config["users"][1]["lock_passwd"] is True
    assert config["ssh_pwauth"] is False
    script = config["write_files"][0]["content"]
    assert "apt-get -y install ubuntu-desktop xrdp xorgxrdp" in script
    assert "port=tcp://127.0.0.1:3389" in script
    assert "GNOME_SHELL_SESSION_MODE=ubuntu" in script
    assert script.index("adduser xrdp ssl-cert") < script.index("systemctl restart xrdp")
    assert script.index("port=tcp://127.0.0.1:3389") < script.index("systemctl restart xrdp")
    files = {item["path"]: item["content"] for item in config["write_files"]}
    cloud_network = yaml.safe_load(
        files["/etc/cloud/cloud.cfg.d/99-microsegmentation-lab-network.cfg"]
    )
    netplan = yaml.safe_load(files["/etc/netplan/90-microsegmentation-lab.yaml"])
    nic = netplan["network"]["ethernets"]["lab-nic"]
    assert cloud_network["network"]["config"] == "disabled"
    assert nic["match"] == {"name": "en*"}
    assert nic["renderer"] == "networkd"
    assert nic["dhcp4"] is True
    assert script.index("netplan apply") < script.index("apt-get update")
    assert config["runcmd"] == [["bash", "/usr/local/sbin/configure-lab-desktop"]]
    subprocess.run(["bash", "-n"], input=script, text=True, check=True)


def test_vm_manifest_encodes_definition() -> None:
    blueprint = load_blueprint("ubuntu-server")
    manifest = vm_manifest(WEB, blueprint, "#cloud-config")
    assert manifest["metadata"]["namespace"] == "web"
    assert manifest["spec"]["runStrategy"] == "Always"
    domain = manifest["spec"]["template"]["spec"]["domain"]
    assert domain["cpu"]["cores"] == 2
    assert domain["memory"]["guest"] == "2Gi"
    assert domain["devices"]["interfaces"][0]["ports"] == [{"port": 22}, {"port": 8080}]
    dv = manifest["spec"]["dataVolumeTemplates"][0]
    assert dv["spec"]["storage"]["resources"]["requests"]["storage"] == "10Gi"
    assert dv["spec"]["source"]["http"]["url"] == blueprint.image_url


def test_halted_when_run_false() -> None:
    stopped = VMDef(
        name="db-01",
        blueprint="rocky-server",
        size=WEB.size,
        segment="db",
        ports=(22,),
        run=False,
    )
    manifest = vm_manifest(stopped, load_blueprint("rocky-server"), "#cloud-config")
    assert manifest["spec"]["runStrategy"] == "Halted"


def test_guest_ssh_jumps_via_outer_vm(monkeypatch: pytest.MonkeyPatch, tmp_path: object) -> None:
    monkeypatch.setenv("LAB_STATE_DIR", str(tmp_path))
    argv = guest_ssh_command(OUTER, "192.168.122.57", "web-01", "10.42.0.10", "labadmin")
    assert argv[-1] == "labadmin@10.42.0.10"
    proxy = next(a for a in argv if a.startswith("ProxyCommand="))
    assert "labadmin@192.168.122.57" in proxy
    assert "-W %h:%p" in proxy
    assert any("web-01_ed25519" in a for a in argv)
