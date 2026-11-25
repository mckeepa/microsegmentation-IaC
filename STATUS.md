# Implementation Checkpoint — 2026-11-14

## VM image build requirements — 2026-11-25

- **Pending (FR-2.7):** Add an image-building tool or workflow to preinstall
  desktop software and updates in reusable, versioned VM images, so new VMs
  start more quickly. Keep instance-specific settings and secrets out of the
  image; configure them when each VM is created.
- **Pending (FR-2.8):** Allow a prebuilt image to be patched and saved as a new
  version for future VMs. Patching an image does not patch existing VM disks;
  never replace those disks silently.
- When implementing the workflow, include instructions for building,
  patching, verifying and using image versions, and for patching existing VMs
  separately. The tool and workflow have not yet been implemented.

## Switchboard requirement — 2026-11-25

- **Pending (FR-5.4):** Show each VM's image import phase and percentage during
  provisioning, plus progress for other long-running tasks where available.
  Show the state when a percentage is unavailable, and distinguish image
  import progress from overall desktop installation. The switchboard has not
  yet been implemented.

## Update — 2026-11-21

- Added a Rocky desktop blueprint, a `desk-01` definition, and `lab rdp --all`
  for RDP-configured VMs. Stopped or unreachable VMs are reported, not started.
- The new desktop and tunnels have **not** been tested end-to-end. The existing
  CDI HTTP importer does not verify the blueprint image SHA-256.

Branch `v2-20261114`. This is the resume point after a deliberate stop (laptop
shutdown). The lab was **healthy and all verifications below passed** when the
outer VM was shut down.

## Resume in two commands

```sh
uv run lab up --start-vm   # starts the outer VM, waits for SSH + pod recovery, prints health
uv run lab vm list         # web-01 and db-01 should return to Running/Ready
```

If anything fails, `lab status` ends with a `NEXT:` hint.

## Where the implementation is up to

| Phase | State |
| --- | --- |
| 0 — requirements/design | Done ([requirements/](requirements/), [design/](design/)) |
| 1 — foundation | **Done and verified**: `lab provision` (outer VM + K3s v1.36.5+k3s1 + Cilium 1.20.4 + KubeVirt v1.9.1 + CDI v1.66.1), `lab status`, `lab up` (verified with a real outer-VM restart) |
| 2 — VM lifecycle | **Core done and verified**: blueprints (`ubuntu-server`, `rocky-server`), `lab vm apply/list/start/stop/restart/delete`, `lab ssh <vm>` (jump via outer VM). Verified: `lab ssh web-01 -- hostname` → `web-01`; `lab ssh db-01` → Rocky 10.2. **Remaining**: `rocky-desktop` blueprint, `lab rdp`, `lab vm console`, `lab vm set-password` |
| 3 — microsegmentation | Not started. First task: the phase gate — prove Cilium enforces NetworkPolicy on guest traffic (FR-4.2) |
| 4 — switchboard web UI | Not started |

## Live state at shutdown

- Outer VM `lab2-20261114-k8s` (8 vCPU / 32 GiB / 150 GiB), last IP
  192.168.122.57 (DHCP — rediscovered automatically, never assume it).
- Guests (from [lab.yaml](lab.yaml)): `web-01` (ubuntu-server, seg web) and
  `db-01` (rocky-server, seg db), both reached Running/Ready; root-image
  imports Succeeded 100%. `desk-01` is commented out in lab.yaml until the
  rocky-desktop blueprint exists.
- `state/` holds all keys/kubeconfig/audit-logs (gitignored, survives reboot).
- v1 lab is fully torn down; `main` is reference-only.

## Next work items (in order)

1. `rocky-desktop` blueprint (XFCE + xrdp) + `lab rdp desk-01` tunnel +
   `lab vm set-password`; re-enable desk-01 in lab.yaml.
2. Phase-3 gate: apply a deny policy between segments and prove allowed/denied
   flows with real guest traffic (`lab policy apply/test`, FR-4).
3. `lab vm console` (needs virtctl on the host or via outer VM).
4. Switchboard (`lab web`, FR-5) reusing the same Python core.

## Notes and gotchas discovered this session (already fixed in code)

- Autoinstall's final reboot leaves the domain shut off; `wait_for_ssh`
  restarts it and (only in that flow) drops the installer's transient SSH host
  key ([host.py](src/lab/host.py)).
- CDI does not know K3s's `local-path` provisioner: its StorageProfile needs
  `claimPropertySets` (access mode) or every DataVolume fails with
  `ErrClaimNotValid`; `install_cdi` now patches it ([cluster.py](src/lab/cluster.py)).
- Guest SSH is a ProxyCommand jump through the outer VM to the launcher pod IP;
  masquerade only forwards ports declared in lab.yaml. Note for phase 3:
  NetworkPolicies will affect this path (it rides the pod network) — expect to
  move to a virtctl/API-server path when policies land.
