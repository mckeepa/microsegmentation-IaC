"""Declarative VM lifecycle: reconcile lab.yaml onto KubeVirt (FR-2).

Each VM definition references a blueprint (blueprints/<name>/) that owns
everything OS-specific: pinned image URL, cloud-init template, default user.
Reconciliation builds Namespace + VirtualMachine manifests and applies them
through the cluster's kubectl over audit-logged SSH. VM run state is
declarative via runStrategy; deletion always requires explicit confirmation.
"""

import json
from dataclasses import dataclass
from typing import Any

import typer
import yaml

from lab.cluster import Cluster
from lab.config import REPO_ROOT, VMDef
from lab.host import ProvisionError, ensure_keypair

BLUEPRINTS_DIR = REPO_ROOT / "blueprints"
MANAGED_LABEL = "lab.local/managed-by"
MANAGED_VALUE = "microsegmentation-iac-v2"
KUBECTL = "sudo k3s kubectl"


@dataclass(frozen=True)
class Blueprint:
    name: str
    image_url: str
    image_sha256: str
    os: str
    user: str
    user_data_template: str


def load_blueprint(name: str) -> Blueprint:
    folder = BLUEPRINTS_DIR / name
    spec_path = folder / "blueprint.yaml"
    template_path = folder / "user-data.yaml"
    if not spec_path.is_file() or not template_path.is_file():
        available = sorted(p.name for p in BLUEPRINTS_DIR.iterdir() if p.is_dir())
        raise ProvisionError(f"unknown blueprint {name!r}; available: {available}")
    spec = yaml.safe_load(spec_path.read_text())
    return Blueprint(
        name=name,
        image_url=str(spec["image_url"]),
        image_sha256=str(spec["image_sha256"]),
        os=str(spec["os"]),
        user=str(spec["user"]),
        user_data_template=template_path.read_text(),
    )


def render_guest_user_data(blueprint: Blueprint, hostname: str, public_key: str) -> str:
    return blueprint.user_data_template.format(
        hostname=hostname, user=blueprint.user, ssh_public_key=public_key
    )


def namespace_manifest(segment: str) -> dict[str, Any]:
    return {
        "apiVersion": "v1",
        "kind": "Namespace",
        "metadata": {
            "name": segment,
            "labels": {MANAGED_LABEL: MANAGED_VALUE, "lab.local/segment": segment},
        },
    }


def vm_manifest(vm: VMDef, blueprint: Blueprint, user_data: str) -> dict[str, Any]:
    labels = {
        MANAGED_LABEL: MANAGED_VALUE,
        "lab.local/blueprint": blueprint.name,
        "lab.local/segment": vm.segment,
        "kubevirt.io/vm": vm.name,
    }
    return {
        "apiVersion": "kubevirt.io/v1",
        "kind": "VirtualMachine",
        "metadata": {"name": vm.name, "namespace": vm.segment, "labels": labels},
        "spec": {
            "runStrategy": "Always" if vm.run else "Halted",
            "dataVolumeTemplates": [
                {
                    "metadata": {"name": f"{vm.name}-root"},
                    "spec": {
                        "storage": {
                            "resources": {"requests": {"storage": f"{vm.size.disk_gib}Gi"}}
                        },
                        "source": {"http": {"url": blueprint.image_url}},
                    },
                }
            ],
            "template": {
                "metadata": {"labels": labels},
                "spec": {
                    "domain": {
                        "cpu": {"cores": vm.size.vcpus},
                        "memory": {"guest": f"{vm.size.memory_gib}Gi"},
                        "devices": {
                            "disks": [
                                {"name": "root", "disk": {"bus": "virtio"}},
                                {"name": "cloudinit", "disk": {"bus": "virtio"}},
                            ],
                            "interfaces": [
                                {
                                    "name": "default",
                                    "masquerade": {},
                                    "ports": [{"port": port} for port in vm.ports],
                                }
                            ],
                        },
                    },
                    "networks": [{"name": "default", "pod": {}}],
                    "volumes": [
                        {"name": "root", "dataVolume": {"name": f"{vm.name}-root"}},
                        {"name": "cloudinit", "cloudInitNoCloud": {"userData": user_data}},
                    ],
                },
            },
        },
    }


def _apply(cluster: Cluster, manifests: list[dict[str, Any]], description: str) -> str:
    document = yaml.safe_dump_all(manifests, sort_keys=False)
    result = cluster.rsh(f"{KUBECTL} apply -f -", description, input_text=document)
    return str(result.stdout).strip()


def apply_vms(cluster: Cluster, vms: tuple[VMDef, ...]) -> None:
    """Reconcile all lab.yaml VM definitions onto the cluster (FR-2.2)."""
    if not vms:
        typer.echo("No VMs defined in lab.yaml.")
        return
    manifests = [namespace_manifest(segment) for segment in sorted({vm.segment for vm in vms})]
    for vm in vms:
        blueprint = load_blueprint(vm.blueprint)
        _, public_key = ensure_keypair(vm.name)
        user_data = render_guest_user_data(blueprint, vm.name, public_key)
        manifests.append(vm_manifest(vm, blueprint, user_data))
    output = _apply(cluster, manifests, f"apply {len(vms)} VM definitions")
    typer.echo(output)
    typer.echo(
        "Applied. First-time image imports run in the cluster for a few minutes; "
        "watch with `lab vm list`."
    )


def _get_managed_json(cluster: Cluster, kind: str) -> list[dict[str, Any]]:
    result = cluster.rsh(
        f"{KUBECTL} get {kind} -A -l {MANAGED_LABEL}={MANAGED_VALUE} -o json",
        f"list managed {kind}",
        check=False,
    )
    if result.returncode != 0:
        return []
    items = json.loads(result.stdout).get("items", [])
    return list(items)


def list_vms(cluster: Cluster) -> None:
    """Show status, IP, sizing, ports, and access for every managed VM (FR-2.4)."""
    vms = _get_managed_json(cluster, "vm")
    vmis = {
        (i["metadata"]["namespace"], i["metadata"]["name"]): i
        for i in _get_managed_json(cluster, "vmi")
    }
    if not vms:
        typer.echo("No managed VMs found. Define them in lab.yaml and run `lab vm apply`.")
        return
    header = (
        f"{'NAME':<12} {'SEGMENT':<8} {'BLUEPRINT':<14} {'STATUS':<14} "
        f"{'READY':<6} {'IP':<15} PORTS"
    )
    typer.echo(header)
    for vm in vms:
        meta = vm["metadata"]
        key = (meta["namespace"], meta["name"])
        vmi = vmis.get(key, {})
        interfaces = vmi.get("status", {}).get("interfaces", [])
        ip = interfaces[0].get("ipAddress", "") if interfaces else ""
        ports = vm["spec"]["template"]["spec"]["domain"]["devices"]["interfaces"][0].get(
            "ports", []
        )
        ready = next(
            (
                c["status"]
                for c in vm.get("status", {}).get("conditions", [])
                if c["type"] == "Ready"
            ),
            "False",
        )
        typer.echo(
            f"{meta['name']:<12} {meta['namespace']:<8} "
            f"{meta['labels'].get('lab.local/blueprint', '?'):<14} "
            f"{vm.get('status', {}).get('printableStatus', 'Unknown'):<14} "
            f"{ready:<6} {ip:<15} {','.join(str(p['port']) for p in ports)}"
        )


def _managed_vm_namespace(cluster: Cluster, name: str) -> str:
    """Resolve a managed VM's namespace; refuse unmanaged VMs (FR-1.5)."""
    for vm in _get_managed_json(cluster, "vm"):
        if vm["metadata"]["name"] == name:
            return str(vm["metadata"]["namespace"])
    raise ProvisionError(f"no managed VM named {name!r}; see `lab vm list`")


def set_run_strategy(cluster: Cluster, name: str, strategy: str) -> None:
    namespace = _managed_vm_namespace(cluster, name)
    patch = json.dumps({"spec": {"runStrategy": strategy}})
    cluster.rsh(
        f"{KUBECTL} patch vm {name} -n {namespace} --type=merge -p '{patch}'",
        f"set {name} runStrategy={strategy}",
    )
    typer.echo(f"{name}: runStrategy={strategy} (note: `lab vm apply` resets this to lab.yaml).")


def restart_vm(cluster: Cluster, name: str) -> None:
    namespace = _managed_vm_namespace(cluster, name)
    cluster.rsh(
        f"{KUBECTL} delete vmi {name} -n {namespace} --ignore-not-found",
        f"restart {name} by deleting its instance",
        timeout=120,
    )
    typer.echo(f"{name}: instance deleted; KubeVirt recreates it if runStrategy is Always.")


def delete_vm(cluster: Cluster, name: str) -> None:
    """Delete a managed VM and its disks after explicit confirmation (FR-2.2)."""
    namespace = _managed_vm_namespace(cluster, name)
    confirmation = typer.prompt(
        f"This permanently deletes {name} and its disk. Type 'delete {name}' to continue"
    )
    if confirmation != f"delete {name}":
        typer.echo("Confirmation did not match; nothing deleted.")
        raise typer.Exit(1)
    cluster.rsh(f"{KUBECTL} delete vm {name} -n {namespace}", f"delete VM {name}", timeout=120)
    typer.echo(f"{name} deleted. Remove it from lab.yaml or the next apply recreates it.")
