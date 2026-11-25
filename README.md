# KubeVirt Home Lab — v2

A restart of the microsegmentation lab on a clean branch. The old implementation
lives on `main` for reference. The v1 outer VM was removed during the restart;
v2 uses a separate outer VM.

**Goal in one line:** declaratively run VMs (with and without desktops) on
Kubernetes/KubeVirt, and get an SSH or RDP session to any of them in one command.

## Run the lab

Run these commands from the **repository root on the laptop**, not inside a
guest VM. Requires Python 3.12+ and [uv](https://docs.astral.sh/uv/).

### 1. Start and check the lab

```sh
uv sync                      # install dependencies into .venv
uv run lab up --start-vm     # start the outer VM and wait for recovery
uv run lab status            # check the outer VM and cluster
```

Check that `lab status` reports `OK` for the outer VM, K3s, the node,
Cilium, KubeVirt and CDI. If it reports a failure, follow its `NEXT:` message
before proceeding. This check does not verify every service inside every
guest.

For a fuller Kubernetes pod check, run the following **on the laptop**, from
the repository root. It discovers the outer VM's current IP and runs `k3s`
inside that VM over SSH. Do not run `sudo k3s` directly on the laptop.

```sh
VM_NAME=lab2-20261114-k8s  # outer_vm.name in lab.yaml
VM_IP=$(virsh -c qemu:///system domifaddr "$VM_NAME" --source lease |
  awk '$3 == "ipv4" { split($4, a, "/"); print a[1]; exit }')
if [ -n "$VM_IP" ]; then
  ssh -i "state/secrets/${VM_NAME}_ed25519" -o IdentitiesOnly=yes \
    -o "UserKnownHostsFile=state/secrets/${VM_NAME}_known_hosts" \
    "labadmin@$VM_IP" 'sudo -n k3s kubectl get pods -A'
else
  echo "No DHCP address found; check the outer VM with uv run lab status." >&2
fi
```

Check that long-running pods are `Running` and ready, and completed jobs are
`Completed`. Investigate pods in error or crash-loop states. This direct SSH
command does not go through the `lab` audit logger.

### 2. List guest VMs

```sh
uv run lab vm list
```

This lists project-managed KubeVirt VMs with their status, readiness, IP and
ports. `Running` and `READY True` indicate that the VM is running and ready;
they do not guarantee that its applications or desktop services are ready.
VMs only defined in [lab.yaml](lab.yaml), but not yet created, will not appear.

To start an already-created VM that is stopped:

```sh
uv run lab vm start desk-01  # replace desk-01 with the VM name
uv run lab vm list
```

For command help, use `uv run lab --help` or `uv run lab vm --help`.
For development checks, run `make check`.

### Verify a guest image

To download a blueprint's image into `state/cache/` and verify its SHA-256:

```sh
uv run lab image fetch ubuntu-desktop  # replace with a blueprint name
```

The cache is verified again on reuse. **This does not yet change VM
provisioning:** `lab vm apply` still imports independently from the URL
through CDI, so its downloads are not checksum-verified.

## Where to start

| Folder | Contents |
| --- | --- |
| [requirements/](requirements/) | What v2 must do, in what order, and what we learned from v1 |
| [design/](design/) | Proposed repository structure and architecture for the solution |
| [src/lab/](src/lab/) | The Python package behind the `lab` CLI — all logic lives here |
| [tests/](tests/) | pytest suite, run via `make check` |
| `state/` (gitignored) | Local runtime state — `state/secrets/` (keys, kubeconfig, passwords), `state/cache/` (downloaded images), `state/logs/` (audit log of every external command) — never committed |

## Provision and access the outer VM

```sh
uv run lab provision   # idempotent: creates the outer VM from lab.yaml, or reports it
```

SSH to the outer VM (`lab ssh` will wrap this in phase 2). Its IP is a DHCP
lease that can change after any restart, so discover it — never hardcode it:

```sh
VM_NAME=lab2-20261114-k8s   # outer_vm.name in lab.yaml
VM_IP=$(virsh -c qemu:///system domifaddr "$VM_NAME" --source lease |
  awk '$3 == "ipv4" { split($4, a, "/"); print a[1]; exit }')
ssh -i "state/secrets/${VM_NAME}_ed25519" -o IdentitiesOnly=yes \
  -o "UserKnownHostsFile=state/secrets/${VM_NAME}_known_hosts" \
  "labadmin@$VM_IP"
```

Login is key-only (the key is generated into `state/secrets/` by `lab
provision`); the account has passwordless sudo and no usable password.

## Desktop RDP

The VMs run under KubeVirt in Kubernetes pods; RDP connects to a **desktop
guest VM**, not directly to a container. Only VMs with an `rdp` entry in
[lab.yaml](lab.yaml) are selected.

**Current limitation:** the Ubuntu desktop has been accessed over RDP after
manual fixes, but provisioning a fresh VM with the updated blueprint and
restarting it have not yet been tested end-to-end. The existing VM importer
downloads images directly through CDI without checking the blueprint's
SHA-256; do not rely on that value as verification. A definition in
`lab.yaml` alone does not create a VM.

### Ubuntu GNOME desktop

The `ubuntu-desktop` definition uses Ubuntu 24.04 with the standard Ubuntu
GNOME desktop and xrdp, 4 vCPUs, 8 GiB RAM, 40 GiB disk and local port
`13390`. It starts with `run: false`; change that to `true` in
[lab.yaml](lab.yaml) if it should also start automatically after later applies.

**Before applying:** `lab vm apply` reconciles **every** VM in `lab.yaml`,
including its `run` value. For example, it stops `desk-01` if that VM is
running while its definition says `run: false`. Review the run states against
`uv run lab vm list` and adjust them before applying. Ensure the outer VM has
enough free CPU, memory and disk for the additional desktop.

Run on the laptop, from the repository root:

```sh
uv run lab vm apply
uv run lab vm start ubuntu-desktop
uv run lab vm list
```

While the VM is `Provisioning`, check its image import progress from the
laptop with this temporary troubleshooting command:

```sh
uv run python - <<'PY'
from lab.cluster import Cluster
from lab.config import load_config

cluster = Cluster(load_config().outer_vm)
result = cluster.rsh(
    "sudo k3s kubectl get datavolume ubuntu-desktop-root -n mgmt -o wide",
    "inspect Ubuntu desktop image import",
)
print(result.stdout, end="")
PY
```

The `PROGRESS` column is the CDI image import percentage, not the progress of
the entire desktop installation. This command uses the lab's audit-logged SSH
runner. For another VM, replace the DataVolume name and namespace.

Once the VM is running and has an IP, check first-boot installation:

```sh
uv run lab ssh ubuntu-desktop -- sudo cloud-init status --wait
```

Cloud-init does not report an overall completion percentage. To watch the
installation while the command above is waiting, open a second laptop terminal
in the repository root and run:

```sh
uv run lab ssh ubuntu-desktop -- sudo tail -n 0 -f /var/log/cloud-init-output.log
```

Press `Ctrl+C` to stop watching; installation continues. A percentage shown in
the log applies to that individual download or operation, not the entire
installation.

Proceed only if cloud-init reports `status: done`. If it reports an error, use
`uv run lab ssh ubuntu-desktop -- sudo cloud-init status --long` for details.
During package installation, systemd may report that `colord`,
`gnome-remote-desktop` or `speech-dispatcher` users do not yet exist. If
cloud-init finishes successfully, check for incomplete packages with
`uv run lab ssh ubuntu-desktop -- sudo dpkg --audit`; no output indicates no
packages were reported by that check.
Then set a password for the separate, initially locked `desktop` account and
open its loopback tunnel:

```sh
uv run lab vm set-password ubuntu-desktop
uv run lab rdp ubuntu-desktop
xfreerdp /v:127.0.0.1:13390 /u:desktop /d: /cert:tofu /dynamic-resolution
```

For this desktop, FreeRDP 2.11.5 (`xfreerdp`, from `freerdp2-x11` on Ubuntu)
was verified to resize dynamically. FreeRDP 3.32.2 (`xfreerdp3`) disconnected
when resizing in this lab. With trust-on-first-use, verify the certificate
fingerprint on first connection against the guest over SSH:

```sh
uv run lab ssh ubuntu-desktop -- sudo openssl x509 -in /etc/xrdp/cert.pem -noout -fingerprint -sha256
```

Select **Xorg** if the xrdp login screen asks for a session, and log in as
`desktop` with the password you set. SSH remains key-only. Log out of the
graphical console session before using RDP, or vice versa.

### Rocky desktop and all-desktop tunnels

Once an RDP-configured desktop VM has been created and is running, its desktop
account needs a password. For `desk-01`, set it interactively on first use:

```sh
uv run lab vm set-password desk-01
```

Open loopback tunnels for all configured, running desktops, or just one:

```sh
uv run lab rdp --all
# Or: uv run lab rdp desk-01
```

The command prints the local port and user for each tunnel. For the `desk-01`
settings in [lab.yaml](lab.yaml), connect from the laptop with FreeRDP:

```sh
xfreerdp3 /v:127.0.0.1:13389 /u:desktop /d: /cert:tofu /dynamic-resolution
```

Use the printed port and user for other desktops. `--all` reports stopped or
unreachable desktops without starting them and returns a nonzero status if any
cannot be opened. Each desktop needs a unique `rdp.local_port`. Tunnels bind
only to the laptop's loopback interface and must be reopened after a restart.

## Status

- [x] Phase 0 — requirements and structure defined (this branch)
- [x] Phase 1 — foundation: outer VM + K3s + KubeVirt, one health command
      (`lab provision`, `lab status`, `lab up`)
- [ ] Phase 2 — VM lifecycle and SSH implemented; Ubuntu desktop and RDP
      tunnels need end-to-end validation
- [ ] Phase 3 — microsegmentation: NetworkPolicy test harness on guest traffic
- [ ] Phase 4 — switchboard: web UI for status and tasks, reusing the same core

See [STATUS.md](STATUS.md) for the latest implementation checkpoint and resume
steps, [requirements/00-vision.md](requirements/00-vision.md) for scope and
[design/00-proposed-structure.md](design/00-proposed-structure.md) for the plan.
