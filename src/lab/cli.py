"""The `lab` CLI - the single entry point for every operation (NFR-1.1).

Commands are registered up front with their phase so `lab --help` shows the
full surface; unimplemented ones exit with NOT_IMPLEMENTED_EXIT_CODE and say
which phase delivers them.
"""

from collections.abc import Iterator
from contextlib import contextmanager
from typing import Annotated, Any

import typer

app = typer.Typer(
    no_args_is_help=True,
    help="Declarative KubeVirt home lab: VMs on Kubernetes with one-command SSH/RDP.",
)
vm_app = typer.Typer(no_args_is_help=True, help="Declarative VM lifecycle (phase 2).")
policy_app = typer.Typer(
    no_args_is_help=True, help="Microsegmentation policies and tests (phase 3)."
)
app.add_typer(vm_app, name="vm")
app.add_typer(policy_app, name="policy")

NOT_IMPLEMENTED_EXIT_CODE = 3


def _todo(phase: int) -> None:
    typer.secho(
        f"Not implemented yet - planned for phase {phase} (see requirements/10-functional.md).",
        err=True,
        fg=typer.colors.YELLOW,
    )
    raise typer.Exit(NOT_IMPLEMENTED_EXIT_CODE)


@app.command()
def status() -> None:
    """Report host, outer VM, cluster, and per-VM health with a NEXT: hint (FR-1.3)."""
    from lab import cluster
    from lab.config import ConfigError, load_config

    try:
        lab_config = load_config()
        raise typer.Exit(cluster.status(lab_config.outer_vm))
    except ConfigError as error:
        typer.secho(f"Error: {error}", err=True, fg=typer.colors.RED)
        raise typer.Exit(1) from None


@app.command()
def up(
    start_vm: Annotated[
        bool, typer.Option("--start-vm", help="Start the outer VM without prompting.")
    ] = False,
) -> None:
    """Recover the whole lab after a laptop or outer-VM restart (FR-1.4)."""
    from lab import cluster, host
    from lab.config import ConfigError, load_config

    try:
        lab_config = load_config()
        raise typer.Exit(cluster.up(lab_config.outer_vm, start_vm=start_vm))
    except (ConfigError, host.ProvisionError) as error:
        typer.secho(f"Error: {error}", err=True, fg=typer.colors.RED)
        raise typer.Exit(1) from None


@app.command()
def provision(
    dry_run: Annotated[
        bool, typer.Option("--dry-run", help="Preview without creating anything.")
    ] = False,
) -> None:
    """Provision the outer VM and the K3s/Cilium/KubeVirt/CDI stack (FR-1.1, FR-1.2)."""
    from lab import cluster, host
    from lab.config import ConfigError, load_config

    try:
        lab_config = load_config()
        host.provision_outer_vm(lab_config.outer_vm, dry_run=dry_run)
        if not dry_run:
            cluster.provision_cluster(lab_config.outer_vm)
    except (ConfigError, host.ProvisionError) as error:
        typer.secho(f"Error: {error}", err=True, fg=typer.colors.RED)
        raise typer.Exit(1) from None
    if not dry_run:
        typer.echo("NEXT: run `lab status` to verify, then define VMs in lab.yaml (phase 2).")


@app.command()
def _connect() -> "tuple[Any, Any]":
    """Load config and connect to the cluster, exiting cleanly on known errors."""
    from lab.cluster import Cluster
    from lab.config import ConfigError, load_config
    from lab.host import ProvisionError

    try:
        lab_config = load_config()
        return lab_config, Cluster(lab_config.outer_vm)
    except (ConfigError, ProvisionError) as error:
        typer.secho(f"Error: {error}", err=True, fg=typer.colors.RED)
        raise typer.Exit(1) from None


@contextmanager
def _vm_errors() -> Iterator[None]:
    """Convert known VM-layer errors to a clean exit."""
    from lab.host import ProvisionError
    from lab.run import CommandError

    try:
        yield
    except (ProvisionError, CommandError) as error:
        typer.secho(f"Error: {error}", err=True, fg=typer.colors.RED)
        raise typer.Exit(1) from None


@app.command()
def ssh(
    vm_name: str,
    command: Annotated[list[str] | None, typer.Argument(help="Optional one-shot command.")] = None,
) -> None:
    """Open an interactive shell (or run a one-shot command) on a guest (FR-3.1)."""
    from lab import access

    lab_config, cluster = _connect()
    with _vm_errors():
        raise typer.Exit(access.ssh_to_vm(cluster, lab_config.outer_vm, vm_name, command or []))


@app.command()
def rdp(vm_name: str) -> None:
    """Open a loopback RDP tunnel to a desktop guest (FR-3.2)."""
    _todo(2)


@app.command()
def web() -> None:
    """Run the local switchboard web UI (FR-5)."""
    _todo(4)


@vm_app.command("apply")
def vm_apply() -> None:
    """Reconcile lab.yaml definitions to the cluster (FR-2.2)."""
    from lab import vms

    lab_config, cluster = _connect()
    with _vm_errors():
        vms.apply_vms(cluster, lab_config.vms)


@vm_app.command("list")
def vm_list() -> None:
    """Show status, IP, sizing, ports, and access methods for every VM (FR-2.4)."""
    from lab import vms

    _, cluster = _connect()
    with _vm_errors():
        vms.list_vms(cluster)


@vm_app.command("start")
def vm_start(vm_name: str) -> None:
    """Start a defined VM (FR-2.5)."""
    from lab import vms

    _, cluster = _connect()
    with _vm_errors():
        vms.set_run_strategy(cluster, vm_name, "Always")


@vm_app.command("stop")
def vm_stop(vm_name: str) -> None:
    """Stop a running VM (FR-2.5)."""
    from lab import vms

    _, cluster = _connect()
    with _vm_errors():
        vms.set_run_strategy(cluster, vm_name, "Halted")


@vm_app.command("restart")
def vm_restart(vm_name: str) -> None:
    """Restart a running VM (FR-2.5)."""
    from lab import vms

    _, cluster = _connect()
    with _vm_errors():
        vms.restart_vm(cluster, vm_name)


@vm_app.command("delete")
def vm_delete(vm_name: str) -> None:
    """Delete a VM after explicit confirmation (FR-2.2)."""
    from lab import vms

    _, cluster = _connect()
    with _vm_errors():
        vms.delete_vm(cluster, vm_name)


@vm_app.command("console")
def vm_console(vm_name: str) -> None:
    """Open the serial/VNC console for boot debugging (FR-2.5)."""
    _todo(2)


@vm_app.command("set-password")
def vm_set_password(vm_name: str) -> None:
    """Set a desktop guest's RDP/graphical password (FR-3.3)."""
    _todo(2)


@policy_app.command("apply")
def policy_apply() -> None:
    """Apply segment and NetworkPolicy manifests (FR-4.1)."""
    _todo(3)


@policy_app.command("test")
def policy_test() -> None:
    """Verify allowed and denied flows with real guest traffic (FR-4.2)."""
    _todo(3)
