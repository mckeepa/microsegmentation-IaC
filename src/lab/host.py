"""Outer VM provisioning and lifecycle on the physical KVM host (FR-1.1, FR-1.5).

Ports v1's provision-lab-vm.sh: Ubuntu autoinstall from a pinned, checksummed
ISO, key-only SSH, passwordless sudo, QEMU guest agent, and the ownership
marker as the libvirt domain title. Deliberate v2 differences: no libvirt
autostart (`lab up` starts the VM with confirmation) and all artifacts live
under state/ instead of work/.
"""

import hashlib
import shutil
import tempfile
import time
from pathlib import Path

import typer

from lab import versions
from lab.config import OuterVM, cache_dir, secrets_dir
from lab.run import CommandError, run

VIRSH = ["virsh", "-c", "qemu:///system"]
REQUIRED_COMMANDS = ("virsh", "virt-install", "xorriso", "ssh-keygen", "openssl", "curl", "ssh")


class ProvisionError(Exception):
    """Provisioning cannot proceed safely."""


def _virsh(args: list[str], description: str, check: bool = True) -> str:
    result = run([*VIRSH, *args], description=description, check=check)
    return result.stdout if result.returncode == 0 else ""


def require_host_commands() -> None:
    for command in REQUIRED_COMMANDS:
        if shutil.which(command) is None:
            raise ProvisionError(f"required command missing on the KVM host: {command}")


def domain_exists(name: str) -> bool:
    result = run(
        [*VIRSH, "dominfo", name], description=f"check whether domain {name} exists", check=False
    )
    return result.returncode == 0


def domain_title(name: str) -> str:
    return _virsh(
        ["desc", name, "--title"], f"read ownership marker of {name}", check=False
    ).strip()


def domain_state(name: str) -> str:
    return _virsh(["domstate", name], f"read state of {name}").strip()


def assert_managed(vm: OuterVM) -> None:
    title = domain_title(vm.name)
    if title != vm.managed_title:
        raise ProvisionError(
            f"domain {vm.name} exists but is not marked as managed by this project "
            f"(title {title!r}); refusing to alter it (FR-1.5)"
        )


def discover_ip(name: str) -> str:
    output = _virsh(
        ["domifaddr", name, "--source", "lease"], f"discover DHCP lease of {name}", check=False
    )
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 4 and fields[2] == "ipv4":
            return fields[3].split("/")[0]
    return ""


def preflight(vm: OuterVM) -> None:
    require_host_commands()
    if not Path("/dev/kvm").exists():
        raise ProvisionError("/dev/kvm is missing; enable KVM virtualization")
    net_info = _virsh(["net-info", vm.network], f"check libvirt network {vm.network}")
    if "Active:         yes" not in net_info:
        raise ProvisionError(f"libvirt network {vm.network!r} must be active")
    pool_info = _virsh(["pool-info", "--bytes", "default"], "check default pool free space")
    available = 0
    for line in pool_info.splitlines():
        if line.startswith("Available:"):
            available = int(line.split(":")[1].strip())
    needed = (vm.disk_gib + 20) * 1024**3
    if available < needed:
        raise ProvisionError(
            f"default storage pool has {available / 1024**3:.0f} GiB free; "
            f"{vm.disk_gib} GiB disk needs at least {needed / 1024**3:.0f} GiB"
        )


def ensure_iso() -> Path:
    """Download and checksum-verify the pinned Ubuntu Server ISO (FR-2.6, NFR-2.3)."""
    iso_path = cache_dir() / versions.UBUNTU_ISO
    if not iso_path.is_file():
        partial = iso_path.with_suffix(".part")
        run(
            [
                "curl",
                "--fail",
                "--location",
                "--show-error",
                "--continue-at",
                "-",
                "--retry",
                "3",
                "--output",
                str(partial),
                versions.UBUNTU_ISO_URL,
            ],
            description=f"download {versions.UBUNTU_ISO}",
            capture=False,
            timeout=3600,
        )
        partial.rename(iso_path)
    digest = hashlib.sha256()
    with iso_path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != versions.UBUNTU_ISO_SHA256:
        raise ProvisionError(
            f"checksum mismatch for {iso_path}; delete it and retry (expected "
            f"{versions.UBUNTU_ISO_SHA256}, got {digest.hexdigest()})"
        )
    return iso_path


def ensure_keypair(name: str) -> tuple[Path, str]:
    """Generate (once) the VM's Ed25519 keypair in state/secrets; return key path and pubkey."""
    key_path = secrets_dir() / f"{name}_ed25519"
    if key_path.is_symlink() or key_path.with_suffix(".pub").is_symlink():
        raise ProvisionError(f"refusing symlinked key material: {key_path}")
    if not key_path.is_file():
        run(
            ["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", str(key_path)],
            description=f"generate SSH keypair for {name}",
        )
    key_path.chmod(0o600)
    public_key = run(
        ["ssh-keygen", "-y", "-f", str(key_path)], description=f"derive public key for {name}"
    ).stdout.strip()
    if not public_key.startswith("ssh-ed25519 "):
        raise ProvisionError(f"an Ed25519 key is required: {key_path}")
    return key_path, public_key


def render_user_data(vm: OuterVM, public_key: str, password_hash: str) -> str:
    """Ubuntu autoinstall config: key-only SSH, passwordless sudo, guest agent."""
    return f"""#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  source:
    id: ubuntu-server
  identity:
    hostname: {vm.name}
    username: {vm.user}
    password: '{password_hash}'
  ssh:
    install-server: true
    authorized-keys:
      - {public_key}
    allow-pw: false
  storage:
    layout:
      name: lvm
      sizing-policy: all
  packages:
    - qemu-guest-agent
    - curl
    - ca-certificates
    - git
    - python3
    - jq
  late-commands:
    - curtin in-target --target=/target -- env DEBIAN_FRONTEND=noninteractive apt-get update
    - curtin in-target --target=/target -- env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
    - |
      curtin in-target --target=/target -- bash -c 'printf "%s\\n" "{vm.user} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-{vm.user} && chmod 0440 /etc/sudoers.d/90-{vm.user} && visudo -cf /etc/sudoers.d/90-{vm.user} && systemctl enable qemu-guest-agent.service'
  updates: security
  shutdown: reboot
"""  # noqa: E501 (autoinstall one-liner must stay a single YAML scalar line)


def build_seed_iso(vm: OuterVM, public_key: str) -> Path:
    """Write the NoCloud autoinstall seed ISO into state/cache."""
    # The account password is random and discarded: login is key-only SSH plus
    # passwordless sudo, so only its hash ever exists (NFR-3.2).
    password_hash = run(
        ["openssl", "passwd", "-6", "-stdin"],
        description="hash throwaway account password",
        input_text=run(
            ["openssl", "rand", "-hex", "32"], description="generate throwaway account password"
        ).stdout.strip(),
    ).stdout.strip()
    seed_iso = cache_dir() / f"{vm.name}-cidata.iso"
    with tempfile.TemporaryDirectory(dir=cache_dir()) as temp:
        seed_dir = Path(temp) / "cidata"
        seed_dir.mkdir(mode=0o700)
        (seed_dir / "user-data").write_text(render_user_data(vm, public_key, password_hash))
        (seed_dir / "meta-data").write_text(f"instance-id: {vm.name}\nlocal-hostname: {vm.name}\n")
        seed_iso.unlink(missing_ok=True)
        run(
            [
                "xorriso",
                "-as",
                "mkisofs",
                "-quiet",
                "-volid",
                "cidata",
                "-joliet",
                "-rock",
                "-output",
                str(seed_iso),
                str(seed_dir),
            ],
            description=f"build autoinstall seed ISO for {vm.name}",
        )
    return seed_iso


def virt_install_args(vm: OuterVM, iso_path: Path, seed_iso: Path) -> list[str]:
    return [
        "virt-install",
        "--connect",
        "qemu:///system",
        "--name",
        vm.name,
        "--memory",
        str(vm.memory_gib * 1024),
        "--vcpus",
        str(vm.vcpus),
        "--cpu",
        "host-passthrough",
        "--osinfo",
        "ubuntu24.04",
        "--metadata",
        f"title={vm.managed_title},description=Managed by microsegmentation-IaC v2",
        "--disk",
        f"pool=default,size={vm.disk_gib},format=qcow2,bus=virtio",
        "--disk",
        f"path={seed_iso},device=cdrom,bus=sata,readonly=on",
        "--network",
        f"network={vm.network},model=virtio",
        "--location",
        f"{iso_path},kernel=casper/vmlinuz,initrd=casper/initrd",
        "--extra-args",
        "autoinstall console=ttyS0,115200n8",
        "--graphics",
        "none",
        "--console",
        "pty,target_type=serial",
        "--boot",
        "hd,cdrom",
        "--noautoconsole",
    ]


def ssh_options(vm: OuterVM) -> list[str]:
    key_path = secrets_dir() / f"{vm.name}_ed25519"
    known_hosts = secrets_dir() / f"{vm.name}_known_hosts"
    return [
        "-i",
        str(key_path),
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=5",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
    ]


def wait_for_ssh(vm: OuterVM, timeout_s: int = 2400) -> str:
    """Wait for autoinstall + reboot + SSH, with a heartbeat (NFR-3.3). Returns the IP."""
    deadline = time.monotonic() + timeout_s
    started = time.monotonic()
    next_status_at = started + 30
    while True:
        # The one-shot install boot ends with the guest's final reboot being a
        # libvirt destroy; starting the domain again boots the installed disk.
        # Probes during the installer phase record the live installer's
        # transient host key, so drop the known-hosts file before the real
        # system's key is pinned.
        if domain_state(vm.name) == "shut off":
            (secrets_dir() / f"{vm.name}_known_hosts").unlink(missing_ok=True)
            _virsh(["start", vm.name], f"boot {vm.name} from disk after autoinstall")
        ip = discover_ip(vm.name)
        if ip:
            probe = run(
                ["ssh", *ssh_options(vm), f"{vm.user}@{ip}", "true"],
                description=f"probe SSH readiness of {vm.name}",
                check=False,
            )
            if probe.returncode == 0:
                return ip
        if time.monotonic() >= deadline:
            raise ProvisionError(
                f"{vm.name} SSH not ready within {timeout_s}s; inspect the install with: "
                f"virsh -c qemu:///system console {vm.name}"
            )
        if time.monotonic() >= next_status_at:
            elapsed = int(time.monotonic() - started)
            state = domain_state(vm.name)
            typer.echo(
                f"Still waiting ({elapsed}s): domain {state}, "
                f"address {ip or 'none yet'} (autoinstall takes ~15-25 min)."
            )
            next_status_at = time.monotonic() + 30
        time.sleep(10)


def provision_outer_vm(vm: OuterVM, dry_run: bool = False) -> None:
    """Create (or adopt) the managed outer VM; idempotent and marker-guarded (FR-1.1)."""
    if domain_exists(vm.name):
        assert_managed(vm)
        state = domain_state(vm.name)
        if dry_run:
            typer.echo(f"Dry run: managed VM {vm.name} exists (state: {state}); no changes.")
            return
        if state == "shut off":
            _virsh(["start", vm.name], f"start existing managed VM {vm.name}")
        typer.echo(f"Managed VM {vm.name} already provisioned (state: {domain_state(vm.name)}).")
        return

    preflight(vm)
    iso_path = ensure_iso()
    _, public_key = ensure_keypair(vm.name)
    seed_iso = build_seed_iso(vm, public_key)
    args = virt_install_args(vm, iso_path, seed_iso)
    if dry_run:
        run([*args, "--dry-run", "--print-xml"], description="preview outer VM XML", capture=False)
        typer.echo("Dry run only: no VM was created.")
        return
    try:
        run(args, description=f"create outer VM {vm.name}", capture=False, timeout=600)
    except CommandError as error:
        raise ProvisionError(f"virt-install failed: {error}") from error
    typer.echo(f"{vm.name} created; Ubuntu autoinstall is running (~15-25 min).")
    ip = wait_for_ssh(vm)
    typer.echo(f"Outer VM ready: {vm.user}@{ip} (key: {secrets_dir() / (vm.name + '_ed25519')})")
