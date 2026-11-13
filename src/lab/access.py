"""SSH access to guests (FR-3.1).

Guests sit behind KubeVirt masquerade networking: they are reachable only on
their launcher pod IP, only on ports declared in lab.yaml, and only from the
cluster network. The outer VM is the cluster node, so guest SSH uses it as a
key-authenticated jump host (ProxyCommand) - no guest is ever exposed
publicly, and every hop is audit-logged (NFR-6).
"""

import json

import typer

from lab.cluster import Cluster
from lab.config import OuterVM, secrets_dir
from lab.host import ProvisionError, ssh_options
from lab.run import run
from lab.vms import KUBECTL, MANAGED_LABEL, MANAGED_VALUE, load_blueprint


def guest_ssh_command(
    outer: OuterVM, outer_ip: str, vm_name: str, guest_ip: str, guest_user: str
) -> list[str]:
    """Build the host-side ssh argv for a guest, jumping via the outer VM."""
    jump = " ".join(["ssh", *ssh_options(outer), "-W", "%h:%p", f"{outer.user}@{outer_ip}"])
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


def _guest_address(cluster: Cluster, name: str) -> tuple[str, str]:
    """Return (guest_ip, guest_user) for a running managed VM."""
    result = cluster.rsh(
        f"{KUBECTL} get vmi -A -l {MANAGED_LABEL}={MANAGED_VALUE} -o json",
        f"resolve address of {name}",
    )
    for vmi in json.loads(result.stdout).get("items", []):
        if vmi["metadata"]["name"] != name:
            continue
        interfaces = vmi.get("status", {}).get("interfaces", [])
        ip = interfaces[0].get("ipAddress", "") if interfaces else ""
        if not ip:
            raise ProvisionError(f"{name} is running but has no address yet; retry shortly")
        blueprint = vmi["metadata"]["labels"].get("lab.local/blueprint", "")
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
