"""SSH access to guests (FR-3.1).

Guests sit behind KubeVirt masquerade networking: they are reachable only on
their launcher pod IP, only on ports declared in lab.yaml, and only from the
cluster network. The outer VM is the cluster node, so guest SSH uses it as a
key-authenticated jump host (ProxyCommand) - no guest is ever exposed
publicly, and every hop is audit-logged (NFR-6).
"""

import hashlib
import json
import shlex
import sys

import typer

from lab.cluster import Cluster
from lab.config import OuterVM, VMDef, secrets_dir
from lab.host import ProvisionError, ssh_options
from lab.run import CommandError, run
from lab.vms import KUBECTL, MANAGED_LABEL, MANAGED_VALUE, load_blueprint


def guest_ssh_command(
    outer: OuterVM, outer_ip: str, vm_name: str, guest_ip: str, guest_user: str
) -> list[str]:
    """Build the host-side ssh argv for a guest, jumping via the outer VM."""
    jump = shlex.join(["ssh", *ssh_options(outer), "-W", "%h:%p", f"{outer.user}@{outer_ip}"])
    key = secrets_dir() / f"{vm_name}_ed25519"
    known_hosts = secrets_dir() / f"{vm_name}_known_hosts"
    return [
        "ssh",
        "-i",
        str(key),
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        "StrictHostKeyChecking=accept-new",
        "-o",
        f"ProxyCommand={jump}",
        f"{guest_user}@{guest_ip}",
    ]


def _guest_address(cluster: Cluster, name: str, *, vm: VMDef | None = None) -> tuple[str, str]:
    """Return (guest_ip, guest_user) for a running managed VM."""
    result = cluster.rsh(
        f"{KUBECTL} get vmi -A -l {MANAGED_LABEL}={MANAGED_VALUE} -o json",
        f"resolve address of {name}",
    )
    for vmi in json.loads(result.stdout).get("items", []):
        if vmi["metadata"]["name"] != name:
            continue
        if vm is not None and vmi["metadata"]["namespace"] != vm.segment:
            continue
        if vm is not None and vmi.get("status", {}).get("phase") != "Running":
            raise ProvisionError(f"{name} is not running; see `lab vm list`")
        blueprint = vmi["metadata"]["labels"].get("lab.local/blueprint", "")
        if vm is not None and blueprint != vm.blueprint:
            raise ProvisionError(f"{name}: running VM blueprint does not match lab.yaml")
        interfaces = vmi.get("status", {}).get("interfaces", [])
        ip = interfaces[0].get("ipAddress", "") if interfaces else ""
        if not ip:
            raise ProvisionError(f"{name} is running but has no address yet; retry shortly")
        return ip, load_blueprint(blueprint).user
    raise ProvisionError(f"no running managed instance named {name!r}; see `lab vm list`")


def ssh_to_vm(cluster: Cluster, outer: OuterVM, name: str, command: list[str]) -> int:
    """Open an interactive shell (or run a one-shot command) on a guest."""
    guest_ip, guest_user = _guest_address(cluster, name)
    argv = guest_ssh_command(outer, cluster.ip, name, guest_ip, guest_user)
    if command:
        argv += ["--", *command]
    else:
        typer.echo(f"Connecting to {guest_user}@{name} ({guest_ip}) via {cluster.ip}...")
    result = run(
        argv,
        description=f"SSH to guest {name}",
        check=False,
        capture=False,
        timeout=None,
    )
    return result.returncode


def patch_vm(cluster: Cluster, vm: VMDef) -> int:
    """Update packages on one running guest without rebooting it."""
    blueprint = load_blueprint(vm.blueprint)
    if blueprint.os == "ubuntu-24.04":
        expected_os = "ubuntu"
        version_pattern = "24.04"
        update = (
            "export DEBIAN_FRONTEND=noninteractive\n"
            "apt-get update\n"
            "apt-get -y -o Dpkg::Options::=--force-confold upgrade --with-new-pkgs\n"
            'if [ -e /run/reboot-required ]; then echo "A reboot is required."; fi\n'
        )
    elif blueprint.os in ("rocky-9", "rocky-10"):
        expected_os = "rocky"
        version = blueprint.os.removeprefix("rocky-")
        version_pattern = f"{version}|{version}.*"
        update = "dnf -y upgrade --refresh\necho 'Check whether a reboot is required.'\n"
    else:
        raise ProvisionError(f"{vm.name}: patching is not supported for {blueprint.os!r}")

    script = (
        "set -eu\n"
        ". /etc/os-release\n"
        f'if [ "$ID" != {shlex.quote(expected_os)} ]; then\n'
        "  echo 'Guest OS does not match the configured blueprint' >&2\n"
        "  exit 1\n"
        "fi\n"
        f'case "$VERSION_ID" in {version_pattern}) ;; *)\n'
        "  echo 'Guest OS version does not match the configured blueprint' >&2\n"
        "  exit 1;;\n"
        "esac\n"
        "cloud-init status --wait\n"
        f"{update}"
    )
    guest_ip, guest_user = _guest_address(cluster, vm.name, vm=vm)
    ssh = guest_ssh_command(cluster.vm, cluster.ip, vm.name, guest_ip, guest_user)
    typer.echo(f"{vm.name}: updating guest packages; this may restart services.")
    result = run(
        [
            *ssh[:-1],
            "-o",
            "BatchMode=yes",
            ssh[-1],
            "sudo",
            "-n",
            "bash",
            "-c",
            shlex.quote(script),
        ],
        description=f"patch guest {vm.name}",
        check=False,
        capture=False,
        timeout=None,
    )
    if result.returncode == 0:
        typer.echo(f"{vm.name}: package update completed; the VM was not rebooted.")
    else:
        typer.secho(
            f"{vm.name}: package update failed (exit {result.returncode}); check output above.",
            err=True,
            fg=typer.colors.RED,
        )
    return result.returncode


def _rdp_vmi_addresses(cluster: Cluster) -> dict[tuple[str, str], str]:
    result = cluster.rsh(
        f"{KUBECTL} get vmi -A -l {MANAGED_LABEL}={MANAGED_VALUE} -o json",
        "list managed VM instances for RDP",
    )
    addresses = {}
    for vmi in json.loads(result.stdout)["items"]:
        status = vmi.get("status", {})
        interfaces = status.get("interfaces", [])
        if status.get("phase") == "Running" and interfaces:
            ip = interfaces[0].get("ipAddress")
            if ip:
                addresses[(vmi["metadata"]["namespace"], vmi["metadata"]["name"])] = ip
    return addresses


def open_rdp_tunnel(cluster: Cluster, vm: VMDef, guest_ip: str) -> None:
    if vm.rdp is None:
        raise ProvisionError(f"{vm.name} is not configured for RDP in lab.yaml")
    blueprint = load_blueprint(vm.blueprint)
    ssh = guest_ssh_command(cluster.vm, cluster.ip, vm.name, guest_ip, blueprint.user)
    identity = f"{vm.segment}/{vm.name}/{guest_ip}/{vm.rdp.local_port}"
    digest = hashlib.sha256(identity.encode()).hexdigest()[:16]
    control = secrets_dir() / f"rdp-{digest}"
    if control.exists() or control.is_symlink():
        if control.is_symlink():
            raise ProvisionError(f"refusing symlinked RDP control socket: {control}")
        run(
            ["ssh", "-S", str(control), "-O", "check", ssh[-1]],
            description=f"check existing RDP tunnel for {vm.name}",
        )
        typer.echo(f"{vm.name}: tunnel already running at 127.0.0.1:{vm.rdp.local_port}")
        return
    run(
        [
            *ssh[:-1],
            "-o",
            "BatchMode=yes",
            "-o",
            "ExitOnForwardFailure=yes",
            "-o",
            "ServerAliveInterval=30",
            "-o",
            "ServerAliveCountMax=3",
            "-f",
            "-N",
            "-M",
            "-S",
            str(control),
            "-L",
            f"127.0.0.1:{vm.rdp.local_port}:127.0.0.1:3389",
            ssh[-1],
        ],
        description=f"open RDP tunnel for {vm.name}",
        capture=False,
        timeout=30,
    )
    typer.echo(f"{vm.name}: 127.0.0.1:{vm.rdp.local_port} (desktop user: {vm.rdp.user})")


def open_rdp_tunnels(cluster: Cluster, vms: tuple[VMDef, ...]) -> int:
    configured = [vm for vm in vms if vm.rdp is not None]
    if not configured:
        typer.echo("No VMs are configured for RDP in lab.yaml.")
        return 0
    addresses = _rdp_vmi_addresses(cluster)
    failed = False
    for vm in configured:
        ip = addresses.get((vm.segment, vm.name))
        if not ip:
            typer.echo(f"{vm.name}: not running or no IP; left unchanged.")
            failed = True
            continue
        try:
            open_rdp_tunnel(cluster, vm, ip)
        except (ProvisionError, CommandError) as error:
            typer.secho(f"{vm.name}: {error}", err=True, fg=typer.colors.RED)
            failed = True
    return int(failed)


def set_desktop_password(cluster: Cluster, vm: VMDef) -> int:
    if vm.rdp is None:
        raise ProvisionError(f"{vm.name} is not configured for RDP in lab.yaml")
    if not sys.stdin.isatty():
        raise ProvisionError("set-password requires an interactive terminal")
    guest_ip, guest_user = _guest_address(cluster, vm.name)
    ssh = guest_ssh_command(cluster.vm, cluster.ip, vm.name, guest_ip, guest_user)
    result = run(
        [*ssh[:-1], "-tt", ssh[-1], "sudo", "-n", "passwd", "--", vm.rdp.user],
        description=f"set desktop password for {vm.name}",
        capture=False,
        check=False,
    )
    return result.returncode
