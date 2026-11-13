# KubeVirt Home Lab — v2

A restart of the microsegmentation lab on a clean branch. The old implementation
lives on `main` for reference; the running lab it built stays untouched until v2
is ready to rebuild it.

**Goal in one line:** declaratively run VMs (with and without desktops) on
Kubernetes/KubeVirt, and get an SSH or RDP session to any of them in one command.

## Quick start (development)

Requires Python 3.12+ and [uv](https://docs.astral.sh/uv/):

```sh
uv sync            # install dependencies into .venv
uv run lab --help  # the single entry point — full command surface
make check         # format check + lint + types + tests (NFR-2.2)
```

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

## Status

- [x] Phase 0 — requirements and structure defined (this branch)
- [ ] Phase 1 — foundation: outer VM + K3s + KubeVirt, one health command
- [ ] Phase 2 — VM lifecycle: declarative add/remove, one-command SSH/RDP
- [ ] Phase 3 — microsegmentation: NetworkPolicy test harness on guest traffic
- [ ] Phase 4 — switchboard: web UI for status and tasks, reusing the same core

See [requirements/00-vision.md](requirements/00-vision.md) for scope and
[design/00-proposed-structure.md](design/00-proposed-structure.md) for the plan.
