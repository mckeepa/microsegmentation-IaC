# Vision and Scope

## Problem

v1 (branch `main`) works but became unmaintainable: ~15 numbered script folders,
no single entry point, duplicated per-VM bash, and docs that drifted from live
state. Finding *which script to run* became harder than the task itself.

## Vision

A small, structured lab platform where:

1. **VMs are declared, not scripted.** Adding a VM means adding a short YAML
   definition and running one reconcile command — never writing a new script.
2. **Access is one command.** `lab ssh <vm>` or `lab rdp <vm>` from the laptop,
   regardless of guest OS or whether it has a desktop.
3. **There is exactly one entry point.** A single `lab` CLI with discoverable
   subcommands (`status`, `up`, `vm`, `ssh`, `rdp`, `policy`) replaces the
   folder maze. A web switchboard later wraps the same core.
4. **Microsegmentation is testable.** NetworkPolicies between VMs are applied
   declaratively and verified against real guest traffic, with pass/fail output.

## In scope (v2)

- Outer VM + K3s + KubeVirt/CDI provisioning on the laptop's KVM host
- Declarative VM lifecycle (create, start, stop, delete) from versioned definitions
- Server guests (Ubuntu, Rocky) and desktop guests (RDP-capable)
- One-command SSH and RDP access
- NetworkPolicy microsegmentation testing between guests
- Web switchboard for status and common tasks (last phase)

## Out of scope (v2)

- Windows guests (revisit after Linux flow is solid; v1 never verified it)
- Monitoring stacks (Headlamp/Cockpit/Prometheus) — `lab status` covers needs
- Azure/NSX/Argo CD integrations (parked from v1)
- Multi-node clusters, HA, public network exposure

## Priorities

Phased, each phase usable on its own — see [README](../README.md#status).
SSH access is core even though RDP is the headline feature: every build,
verify, and repair step depends on it.

## Success criteria

- A newcomer can find the right command for any task from `README.md` +
  `lab --help` alone, in under a minute.
- Adding a new server VM is ≤ 10 lines of YAML and zero new code.
- Laptop reboot → working lab again with one command and no manual repair.
