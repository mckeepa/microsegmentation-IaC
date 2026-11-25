# Proposed Structure

How the solution is laid out to satisfy the [requirements](../requirements/).
This is the plan; refine it as phases land, but keep NFR-1 (≤ 8 top-level
folders, one entry point) inviolable.

## Repository layout

```text
.
├── README.md              # entry point: status, quick start, folder map
├── requirements/          # what and why (this phase's output)
├── design/                # decisions and structure (ADR-style, short)
├── lab.yaml               # THE declarative lab definition (see below)
├── src/lab/               # Python package — all logic lives here
│   ├── cli.py             #   `lab` CLI (typer): status/up/vm/ssh/rdp/policy
│   ├── host.py            #   libvirt outer-VM lifecycle + ownership markers
│   ├── cluster.py         #   K3s/CNI/KubeVirt/CDI install, health, repair
│   ├── vms.py             #   reconcile lab.yaml → KubeVirt objects
│   ├── images.py          #   download/verify/cache/CDI-upload guest images
│   ├── access.py          #   SSH (virtctl tunnel), RDP tunnels, key mgmt
│   ├── policy.py          #   apply policies, run flow test matrix
│   ├── run.py             #   logged runner for ALL external commands (NFR-6)
│   └── versions.py        #   every pinned version + checksum (NFR-2.3)
├── blueprints/            # per-variant VM templates (spec + cloud-init, jinja)
│   ├── ubuntu-server/
│   ├── rocky-server/
│   ├── rocky-desktop/
│   └── ubuntu-desktop/
├── policies/              # segment manifests + declared flow expectations
├── tests/                 # pytest: unit tests + policy test definitions
└── state/                 # gitignored local runtime state
    ├── secrets/           #   keys, known-hosts, kubeconfig, passwords, tunnel PIDs
    ├── cache/             #   checksum-verified downloaded images (ISOs, qcow2)
    └── logs/              #   append-only audit log of every external command (NFR-6)
```

Phase 4 adds `src/lab/web/` (switchboard, FastAPI serving the same core
functions as the CLI) — not a separate app with duplicated logic (FR-5.1).

## The declarative core: `lab.yaml`

One file declares the whole lab; `lab vm apply` reconciles it (FR-2.1/2.2):

```yaml
outer_vm: {name: lab2-20261114-k8s, vcpus: 8, memory_gib: 32, disk_gib: 150}
vms:
  - name: web-01
    blueprint: ubuntu-server
    size: {vcpus: 2, memory_gib: 2, disk_gib: 10}
    segment: web
    ports: [22, 8080]
    run: true
  - name: desk-01
    blueprint: rocky-desktop
    size: {vcpus: 2, memory_gib: 4, disk_gib: 20}
    segment: mgmt
    ports: [22, 3389]
    run: false
```

A **blueprint** owns everything OS-specific (image URL + checksum, cloud-init
template, default user, desktop/RDP setup, NIC-by-name network config). Adding
a VM of an existing kind is YAML-only (FR-2.3); adding a new kind is one new
blueprint folder, not a new script.

## CLI surface (phase mapping)

| Command | Phase | Purpose |
| --- | --- | --- |
| `lab status` / `lab up` | 1 | health with `NEXT:` hint; full restart recovery |
| `lab provision` | 1 | outer VM + cluster install (idempotent, resumable) |
| `lab vm apply/list/start/stop/delete/console/set-password` | 2 | lifecycle |
| `lab ssh <vm> [-- cmd]` / `lab rdp <vm>` | 2 | access |
| `lab policy apply/test` | 3 | segmentation + verification matrix |
| `lab web` | 4 | switchboard |

## Key design decisions (to confirm in phase 1)

1. **CNI: Cilium** (decided — see [constraints](../requirements/30-constraints.md)).
   Chosen over OVN-Kubernetes (v1's worst operational pain, see
   [lessons](../requirements/40-lessons-learned.md)) and for its L7 path:
   CiliumNetworkPolicy enables future Layer 7 inspection/rules (FR-4.4).
   Validate KubeVirt guest-traffic enforcement in phase 1 health checks.
2. **Python packaging:** `uv` + `pyproject.toml`, `typer` for CLI, `ruff` +
   `mypy` + `pytest` as the one-command check (NFR-2.2). Talk to Kubernetes
   via the official `kubernetes` client where practical; shell out to
   `virsh`/`virtctl` behind thin, tested wrappers where the API is impractical.
3. **New names, clean break:** v2 resources use distinct names (outer VM
   `lab2-20261114-k8s`) and their own ownership marker
   (`microsegmentation-iac-v2-<name>`); the v1 lab was torn down before
   provisioning (constraints doc).
4. **Reconcile, don't script:** every mutation flows through
   lab.yaml → desired state → diff → guarded apply. No imperative per-VM
   scripts, ever — that is the v1 failure mode.
