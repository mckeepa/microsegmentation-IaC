# VM Fleet

A single controlling [fleet.json](fleet.json) declares the nested KubeVirt test VMs that should exist, built from **approved blueprints**. Use it to scale up multiple Ubuntu or Rocky servers for microsegmentation tests without writing new scripts. The fleet is separate from the task 30 three-guest matrix (`netpol-test`) and the task 32 desktop; it never modifies those resources.

## The Controlling File

Each entry answers the questions a corporate VM request would: what OS (blueprint), what name (also the guest hostname), how big (CPU/memory/disk), how it is classified (labels for later policy selection), who owns it and why, and whether it should be running.

```jsonc
{
  "namespacePrefix": "seg",
  "defaults": { "adminUser": "labadmin", "timezone": "UTC", "waitSeconds": 1200 },
  "vms": [
    {
      "name": "web-ubuntu-01",          // VM name and guest hostname
      "blueprint": "ubuntu-server",     // must match blueprints/<id>.json
      "cpu": 2, "memory": "2Gi", "disk": "10Gi",
      "labels": { "app": "web", "tier": "frontend", "env": "test" },
      "ports": [8080],                   // forwarded guest ports besides SSH
      "runState": "running",            // or "stopped"
      "owner": "paul",
      "purpose": "Baseline web target for microsegmentation policy tests"
    }
  ]
}
```

- **Namespace per app**: each VM lands in `<namespacePrefix>-<labels.app>` (for example `seg-web`), giving a natural namespace boundary for NetworkPolicies. `labels.app` is required.
- **Labels** are applied to the VM and its pod template, so policy selectors such as `tier=frontend` work immediately. `owner` and `purpose` are stored as annotations.
- **Scaling** is adding entries: `web-ubuntu-02`, `web-ubuntu-03`, … share the blueprint and app namespace but get their own disk, SSH key, and hostname.

## Approved Blueprints

Blueprints pin the OS recipe: checksum-verified cloud image, package set, sudo group, and service names. Only blueprints present in [blueprints/](blueprints) are accepted.

| Blueprint | OS | Provisioning |
| --- | --- | --- |
| `ubuntu-server` | Ubuntu Server 24.04 (noble) cloud image | Fully unattended |
| `rocky-server` | Rocky Linux 9 GenericCloud image | Fully unattended |

Windows Server and Rocky 10 are **not** fleet blueprints: their installation paths (manual ISO; unverified unattended answer file) are handled by task 30 and must not be imitated here until a verified unattended workflow exists.

## Commands

Run from the repository root on the physical host:

```sh
bash scripts/34-vm-fleet/setup-vm-fleet.sh --plan     # show desired state, no cluster access
bash scripts/34-vm-fleet/setup-vm-fleet.sh --apply    # reconcile the cluster to fleet.json
bash scripts/34-vm-fleet/setup-vm-fleet.sh --verify   # re-run per-VM OS/SSH/service checks
bash scripts/34-vm-fleet/setup-vm-fleet.sh --status   # live VM/VMI state per fleet entry
bash scripts/34-vm-fleet/setup-vm-fleet.sh --ssh web-ubuntu-01
bash scripts/34-vm-fleet/setup-vm-fleet.sh --start db-rocky-01
bash scripts/34-vm-fleet/setup-vm-fleet.sh --stop  db-rocky-01
bash scripts/34-vm-fleet/setup-vm-fleet.sh --set-password web-ubuntu-01
bash scripts/34-vm-fleet/setup-vm-fleet.sh --cockpit web-ubuntu-01
```

Apply, per VM: validates the entry and blueprint, generates a dedicated Ed25519 key in ignored `work/<name>_ed25519`, creates or adopts the owned namespace, uploads the checksum-pinned image through CDI into `<name>-disk` (capacity-guarded; one-time per disk), renders key-only cloud-init into Secret `<name>-cloudinit`, creates the VM, reconciles `runState`, and for running VMs waits for SSH (30-second heartbeats with the VMI phase and last SSH error), waits for cloud-init, and verifies the OS, hostname, sudo, agent, and hardened SSH policy. Success for a running VM is its `PASS fleet VM <name> ...` line.

Administration is key-only (`labadmin` with passwordless lab sudo); password and root SSH login are disabled by cloud-init. Private keys and per-VM known-hosts files stay in Git-ignored `work/`. All guest SSH goes through the Kubernetes API via `virtctl`; no service, NodePort, or public listener is created. The declared `ports` list only configures masquerade forwarding inside the VM's pod network for later policy tests.

Fleet VMs have **no password by default** and need none for SSH. `--set-password <name>` interactively sets one for `labadmin`, used for emergency `virtctl console`/VNC login and Cockpit web login; type and confirm it in your terminal, never in files, command arguments, or chat. Setting a password does not enable SSH password login — sshd keeps key-only authentication.

Every fleet blueprint installs **Cockpit** bound to the guest's loopback only (`127.0.0.1:9090`, enforced by a systemd socket drop-in); it is never pod-network reachable because `9090` must not be added to `ports`. Open it per VM with `--cockpit <name>`, which prints a local `https://127.0.0.1:1909x` URL and keeps an SSH tunnel open (Ctrl+C closes it without stopping the VM). Log in as `labadmin` with the password from `--set-password`. The browser shows a self-signed-certificate warning on first use, like the outer VM's Cockpit.

Fleet VMs are **headless servers**: they have no desktop environment and no RDP or VNC service, so `--ssh <name>` is the only interactive access. For a graphical desktop with tunneled RDP, use the separate [task 32 Rocky desktop](../32-rocky-desktop/README.md); its quick start covers starting the VM, setting the password, opening the tunnel, and connecting (including from another machine on the network).

## Safety Rules

- Only resources labeled `microsegmentation-lab/managed-by=microsegmentation-iac` are touched; anything else in the way is refused.
- The tool **never deletes** VMs, disks, Secrets, or namespaces. Removing a `fleet.json` entry leaves its resources in place for explicit manual review and removal.
- An existing PVC or VM that does not match the declared size, image checksum, or disk layout stops the run instead of being replaced.
- Reapplying is idempotent for completed resources: recognized disks are not reuploaded, and an attached OS disk is never uploaded over.
- Changing cloud-init-era settings (admin user, packages) in `fleet.json` does not reconfigure an already-provisioned VM; cloud-init runs on first boot only.

## Capacity

Each new VM needs its disk plus 10 GiB free in the outer VM and its memory plus 2 GiB available. The outer VM currently has 8 vCPUs and 24 GiB RAM shared by all nested guests; count the desktop (6 GiB) and any task 30 guests when planning. Stop fleet VMs you are not using (`runState: "stopped"` and `--apply`, or `--stop <name>`).
