"""K3s + Cilium + KubeVirt + CDI installation and health inside the outer VM (FR-1.2, FR-1.3).

All remote work goes over audit-logged SSH (NFR-6). The install order and
flags encode v1 lessons: K3s must start with Flannel and its embedded
network-policy controller disabled (a CNI is never switched in place), only
one CNI config may exist in /etc/cni/net.d, and Cilium's IPAM pool must match
the K3s cluster CIDR.
"""

import re
import subprocess
import time
from collections.abc import Callable

import typer

from lab import versions
from lab.config import OuterVM, secrets_dir
from lab.host import ProvisionError, discover_ip, ssh_run

KUBECTL = "sudo k3s kubectl"


def k3s_install_command() -> str:
    """K3s pinned install with Flannel + embedded network policy disabled for Cilium."""
    return (
        f"curl -sfL {versions.K3S_INSTALL_URL} | "
        f"INSTALL_K3S_VERSION='{versions.K3S}' sh -s - server "
        "--flannel-backend=none --disable-network-policy "
        "--disable=traefik --disable=servicelb"
    )


def helm_install_command() -> str:
    return f"curl -sfL {versions.HELM_INSTALL_URL} | DESIRED_VERSION='{versions.HELM}' sudo bash"


def cilium_install_command() -> str:
    """Cilium via helm, pinned, IPAM pool matched to the K3s cluster CIDR."""
    helm = "sudo KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm"
    return (
        f"{helm} repo add cilium {versions.CILIUM_HELM_REPO} --force-update >/dev/null"
        f" && {helm} upgrade --install cilium cilium/cilium --version {versions.CILIUM}"
        " --namespace kube-system --set operator.replicas=1"
        f" --set 'ipam.operator.clusterPoolIPv4PodCIDRList={{{versions.K3S_POD_CIDR}}}'"
    )


def rewrite_kubeconfig(kubeconfig: str, ip: str) -> str:
    """Point the exported kubeconfig at the VM's address instead of loopback."""
    return re.sub(r"https://127\.0\.0\.1:6443", f"https://{ip}:6443", kubeconfig)


class Cluster:
    """Operations against one outer VM's cluster."""

    def __init__(self, vm: OuterVM, ip: str | None = None):
        self.vm = vm
        self.ip = ip or discover_ip(vm.name)
        if not self.ip:
            raise ProvisionError(f"{vm.name} has no address; is it running?")

    def rsh(
        self,
        command: str,
        description: str,
        check: bool = True,
        timeout: float | None = 300,
        input_text: str | None = None,
    ) -> subprocess.CompletedProcess[str]:
        return ssh_run(
            self.vm,
            self.ip,
            command,
            description,
            check=check,
            timeout=timeout,
            input_text=input_text,
        )

    def wait_until(
        self, description: str, predicate: Callable[[], bool], timeout_s: int, interval_s: int = 10
    ) -> None:
        deadline = time.monotonic() + timeout_s
        started = time.monotonic()
        next_status_at = started + 30
        typer.echo(f"Waiting up to {timeout_s}s: {description}...")
        while not predicate():
            if time.monotonic() >= deadline:
                raise ProvisionError(f"timed out after {timeout_s}s waiting for: {description}")
            if time.monotonic() >= next_status_at:
                typer.echo(f"Still waiting ({int(time.monotonic() - started)}s): {description}")
                next_status_at = time.monotonic() + 30
            time.sleep(interval_s)

    def _check(self, command: str, description: str) -> bool:
        return self.rsh(command, description, check=False).returncode == 0

    def install_k3s(self) -> None:
        if self._check("systemctl is-active --quiet k3s", "check K3s service"):
            typer.echo("K3s already active.")
        else:
            if not self._check("test -e /dev/kvm", "check nested KVM in outer VM"):
                raise ProvisionError("outer VM has no /dev/kvm; nested virtualization required")
            typer.echo(f"Installing K3s {versions.K3S} (Flannel/network-policy disabled)...")
            self.rsh(k3s_install_command(), "install K3s", timeout=600)
        # Lesson from v1: a second CNI config in /etc/cni/net.d captures pods
        # that start before the real CNI is ready.
        leftovers = self.rsh(
            "sudo ls /etc/cni/net.d 2>/dev/null | grep -v cilium || true",
            "check for conflicting CNI configs",
        ).stdout.strip()
        if leftovers:
            raise ProvisionError(
                f"unexpected CNI configs in /etc/cni/net.d: {leftovers}; remove them first"
            )
        self.wait_until(
            "Kubernetes API answering",
            lambda: self._check(f"{KUBECTL} get --raw /readyz", "probe Kubernetes API"),
            timeout_s=300,
        )

    def install_cilium(self) -> None:
        if not self._check("command -v helm", "check helm presence"):
            typer.echo(f"Installing helm {versions.HELM}...")
            self.rsh(helm_install_command(), "install helm", timeout=300)
        typer.echo(f"Installing Cilium {versions.CILIUM}...")
        self.rsh(cilium_install_command(), "install Cilium via helm", timeout=600)
        self.wait_until(
            "Cilium agent ready and node Ready",
            lambda: self._check(
                f"{KUBECTL} -n kube-system rollout status ds/cilium --timeout=5s"
                f" && {KUBECTL} wait node --all --for=condition=Ready --timeout=5s",
                "probe Cilium/node readiness",
            ),
            timeout_s=600,
        )

    def install_kubevirt(self) -> None:
        base = versions.KUBEVIRT_MANIFEST_BASE
        self.rsh(
            f"{KUBECTL} apply -f {base}/kubevirt-operator.yaml"
            f" && {KUBECTL} apply -f {base}/kubevirt-cr.yaml",
            f"install KubeVirt {versions.KUBEVIRT}",
            timeout=300,
        )
        self.wait_until(
            "KubeVirt phase Deployed",
            lambda: (
                "Deployed"
                in self.rsh(
                    f"{KUBECTL} -n kubevirt get kubevirt kubevirt"
                    " -o jsonpath='{.status.phase}' 2>/dev/null || true",
                    "probe KubeVirt phase",
                    check=False,
                ).stdout
            ),
            timeout_s=900,
        )

    def install_cdi(self) -> None:
        base = versions.CDI_MANIFEST_BASE
        self.rsh(
            f"{KUBECTL} apply -f {base}/cdi-operator.yaml && {KUBECTL} apply -f {base}/cdi-cr.yaml",
            f"install CDI {versions.CDI}",
            timeout=300,
        )
        self.wait_until(
            "CDI phase Deployed",
            lambda: (
                "Deployed"
                in self.rsh(
                    f"{KUBECTL} get cdi cdi -o jsonpath='{{.status.phase}}' 2>/dev/null || true",
                    "probe CDI phase",
                    check=False,
                ).stdout
            ),
            timeout_s=900,
        )
        # K3s local-path is unknown to CDI, so its StorageProfile has no access
        # mode and every DataVolume fails with ErrClaimNotValid. Declare it.
        self.wait_until(
            "local-path StorageProfile created",
            lambda: self._check(f"{KUBECTL} get storageprofile local-path", "probe StorageProfile"),
            timeout_s=120,
        )
        claim_properties = (
            '{"spec":{"claimPropertySets":'
            '[{"accessModes":["ReadWriteOnce"],"volumeMode":"Filesystem"}]}}'
        )
        self.rsh(
            f"{KUBECTL} patch storageprofile local-path --type=merge -p '{claim_properties}'",
            "declare access mode in local-path StorageProfile",
        )

    def export_kubeconfig(self) -> None:
        kubeconfig = self.rsh(
            "sudo cat /etc/rancher/k3s/k3s.yaml", "read cluster kubeconfig"
        ).stdout
        target = secrets_dir() / f"kubeconfig-{self.vm.name}.yaml"
        target.write_text(rewrite_kubeconfig(kubeconfig, self.ip))
        target.chmod(0o600)
        typer.echo(f"Kubeconfig exported: {target}")


def provision_cluster(vm: OuterVM) -> None:
    """Install the pinned K3s/Cilium/KubeVirt/CDI stack; idempotent (FR-1.2)."""
    cluster = Cluster(vm)
    cluster.install_k3s()
    cluster.install_cilium()
    cluster.install_kubevirt()
    cluster.install_cdi()
    cluster.export_kubeconfig()
    typer.echo("Cluster ready: K3s + Cilium + KubeVirt + CDI all deployed.")


# Pods not Running/Completed with full ready counts, as "namespace/name" lines.
UNHEALTHY_PODS_COMMAND = (
    f"{KUBECTL} get pods -A --no-headers 2>/dev/null | "
    'awk \'{split($3,r,"/"); if (($4!="Running" && $4!="Completed" && $4!="Succeeded")'
    ' || ($4=="Running" && r[1]!=r[2])) print $1"/"$2}\''
)


def up(vm: OuterVM, start_vm: bool = False) -> int:
    """Recover the lab after a laptop or outer-VM restart (FR-1.4). Returns exit code."""
    from lab.host import _virsh, assert_managed, domain_exists, domain_state, wait_for_ssh

    if not domain_exists(vm.name):
        typer.secho(f"Error: VM {vm.name} does not exist.", err=True, fg=typer.colors.RED)
        typer.echo("NEXT: run `lab provision` to create it.")
        return 1
    assert_managed(vm)
    state = domain_state(vm.name)
    if state != "running":
        if not start_vm:
            start_vm = typer.confirm(f"Outer VM is {state}. Start it now?", default=True)
        if not start_vm:
            typer.echo(f"Outer VM left {state}. Rerun with --start-vm to start it.")
            return 1
        _virsh(["start", vm.name], f"start outer VM {vm.name}")
    typer.echo("Waiting for outer VM SSH (the DHCP address can change after a restart)...")
    ip = wait_for_ssh(vm, timeout_s=600)
    typer.echo(f"Outer VM SSH ready at {ip}.")

    # v1 lesson: pods that crash-looped during boot need their CrashLoopBackOff
    # timers (up to ~5 min) to expire; wait for recovery instead of deleting them.
    cluster = Cluster(vm, ip=ip)
    unhealthy = ""

    def pods_recovered() -> bool:
        nonlocal unhealthy
        unhealthy = cluster.rsh(
            UNHEALTHY_PODS_COMMAND, "list unhealthy pods", check=False
        ).stdout.strip()
        return unhealthy == ""

    try:
        cluster.wait_until("all pods recovered", pods_recovered, timeout_s=600, interval_s=15)
    except ProvisionError:
        typer.secho(f"Pods still unhealthy after 10 minutes:\n{unhealthy}", fg=typer.colors.RED)
    return status(vm)


def status(vm: OuterVM) -> int:
    """One-screen health report ending in a NEXT: hint (FR-1.3). Returns exit code."""
    from lab.host import domain_exists, domain_state, domain_title

    def line(ok: bool, label: str, detail: str = "") -> bool:
        mark = (
            typer.style("OK ", fg=typer.colors.GREEN)
            if ok
            else typer.style("FAIL", fg=typer.colors.RED)
        )
        typer.echo(f"  [{mark}] {label}" + (f": {detail}" if detail else ""))
        return ok

    typer.echo(f"Outer VM {vm.name}:")
    if not domain_exists(vm.name):
        line(False, "domain exists")
        typer.echo("NEXT: run `lab provision` to create the outer VM.")
        return 1
    if domain_title(vm.name) != vm.managed_title:
        line(False, "ownership marker", "domain exists but is not managed by this project")
        return 1
    state = domain_state(vm.name)
    if not line(state == "running", "domain running", state):
        typer.echo(f"NEXT: start it with: virsh -c qemu:///system start {vm.name}")
        return 1
    ip = discover_ip(vm.name)
    if not line(bool(ip), "DHCP lease", ip or "none"):
        typer.echo("NEXT: wait for boot, then rerun `lab status`.")
        return 1

    cluster = Cluster(vm, ip=ip)
    ssh_ok = line(cluster._check("true", "probe outer VM SSH"), "SSH", f"{vm.user}@{ip}")
    if not ssh_ok:
        typer.echo("NEXT: check the VM console; SSH is not answering.")
        return 1
    typer.echo("Cluster:")
    checks = [
        ("K3s service", "systemctl is-active --quiet k3s"),
        ("node Ready", f"{KUBECTL} wait node --all --for=condition=Ready --timeout=5s"),
        ("Cilium agent", f"{KUBECTL} -n kube-system rollout status ds/cilium --timeout=5s"),
        (
            "KubeVirt Deployed",
            f"{KUBECTL} -n kubevirt get kubevirt kubevirt -o jsonpath='{{.status.phase}}'"
            " | grep -q Deployed",
        ),
        (
            "CDI Deployed",
            f"{KUBECTL} get cdi cdi -o jsonpath='{{.status.phase}}' | grep -q Deployed",
        ),
    ]
    failed = [
        label for label, cmd in checks if not line(cluster._check(cmd, f"status: {label}"), label)
    ]
    if failed:
        typer.echo(f"NEXT: rerun `lab provision` to repair: {', '.join(failed)} not healthy.")
        return 1
    typer.echo("NEXT: lab is healthy. Define VMs in lab.yaml and run `lab vm apply` (phase 2).")
    return 0
