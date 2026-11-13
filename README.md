# KubeVirt Home Lab — v2

A restart of the microsegmentation lab on a clean branch. The old implementation
lives on `main` for reference; the running lab it built stays untouched until v2
is ready to rebuild it.

**Goal in one line:** declaratively run VMs (with and without desktops) on
Kubernetes/KubeVirt, and get an SSH or RDP session to any of them in one command.

## Where to start

| Folder | Contents |
| --- | --- |
| [requirements/](requirements/) | What v2 must do, in what order, and what we learned from v1 |
| [design/](design/) | Proposed repository structure and architecture for the solution |
| `state/` (gitignored) | Local runtime state — `state/secrets/` (keys, kubeconfig, passwords) and `state/cache/` (downloaded images) — never committed |

## Status

- [x] Phase 0 — requirements and structure defined (this branch)
- [ ] Phase 1 — foundation: outer VM + K3s + KubeVirt, one health command
- [ ] Phase 2 — VM lifecycle: declarative add/remove, one-command SSH/RDP
- [ ] Phase 3 — microsegmentation: NetworkPolicy test harness on guest traffic
- [ ] Phase 4 — switchboard: web UI for status and tasks, reusing the same core

See [requirements/00-vision.md](requirements/00-vision.md) for scope and
[design/00-proposed-structure.md](design/00-proposed-structure.md) for the plan.
