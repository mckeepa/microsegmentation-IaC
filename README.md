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

## Status

- [x] Phase 0 — requirements and structure defined (this branch)
- [ ] Phase 1 — foundation: outer VM + K3s + KubeVirt, one health command
- [ ] Phase 2 — VM lifecycle: declarative add/remove, one-command SSH/RDP
- [ ] Phase 3 — microsegmentation: NetworkPolicy test harness on guest traffic
- [ ] Phase 4 — switchboard: web UI for status and tasks, reusing the same core

See [requirements/00-vision.md](requirements/00-vision.md) for scope and
[design/00-proposed-structure.md](design/00-proposed-structure.md) for the plan.
