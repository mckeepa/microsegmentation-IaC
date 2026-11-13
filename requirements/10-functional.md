# Functional Requirements

IDs are stable; reference them in design docs, commits, and tests.

## FR-1 Foundation (phase 1)

- **FR-1.1** Provision the outer KVM VM (Ubuntu Server, libvirt NAT) unattended
  from one command, idempotently: rerunning against an existing managed VM must
  never destroy or reinstall it.
- **FR-1.2** Install a pinned K3s + CNI + KubeVirt + CDI stack inside the outer
  VM from one command, resumable after partial failure.
- **FR-1.3** `lab status` reports host, outer VM, cluster, and per-VM health in
  one screen, ending with a single actionable `NEXT:` hint when unhealthy.
- **FR-1.4** `lab up` recovers the whole lab after a laptop or outer-VM restart:
  start the outer VM (with confirmation), wait for SSH, run guarded network
  repairs, wait for pod recovery, and report VM inventory.
- **FR-1.5** All mutating operations only touch resources carrying the project
  ownership marker; same-named unmanaged resources are refused.

## FR-2 Declarative VM lifecycle (phase 2)

- **FR-2.1** VMs are defined in versioned YAML: name, blueprint (OS/desktop
  variant), vCPU/RAM/disk, labels, exposed ports, and desired run state.
- **FR-2.2** `lab vm apply` reconciles definitions to the cluster: creates
  missing VMs (image import via CDI, cloud-init from the blueprint), applies
  size/label changes where possible, and reports drift. Deleting a definition
  never deletes a VM without an explicit `lab vm delete <name>` confirmation.
- **FR-2.3** Blueprints are shared templates (Ubuntu server, Rocky server,
  Rocky desktop at minimum). Adding a VM from an existing blueprint requires
  YAML only — no new code or scripts.
- **FR-2.4** `lab vm list` shows status, readiness, IP, sizing, labels, exposed
  ports, and supported access methods for every VM.
- **FR-2.5** `lab vm start|stop|restart <name>` manage run state; `lab vm
  console <name>` opens the serial/VNC console for boot debugging.
- **FR-2.6** Guest images are downloaded once, checksum-verified, and cached in
  `work/`.

## FR-3 Access (phase 2)

- **FR-3.1** `lab ssh <vm>` opens an interactive shell to any running guest via
  the Kubernetes API (virtctl tunnel) — key-only auth, no public listeners, no
  passwords. Also supports one-shot commands: `lab ssh <vm> -- <cmd>`.
- **FR-3.2** `lab rdp <vm>` opens (or prints) a tunneled RDP endpoint on
  loopback for desktop guests and reports the port and user; tunnels survive
  the command exiting and are cleaned up/reopened by `lab up`.
- **FR-3.3** Desktop password management: `lab vm set-password <vm>` sets the
  RDP/graphical password; SSH never uses passwords; nothing secret is committed.
- **FR-3.4** Per-VM SSH keys and known-hosts files are generated into `work/`
  automatically and pinned on every connection.

## FR-4 Microsegmentation (phase 3)

- **FR-4.1** Segments (namespaces/labels) and NetworkPolicies are declared in
  versioned manifests applied by `lab policy apply`.
- **FR-4.2** `lab policy test` verifies both allowed and denied flows using real
  guest-originated traffic (not just pod probes), and emits a pass/fail matrix.
- **FR-4.3** Test definitions declare expected reachability (source VM, target
  VM, port, expect allow|deny) alongside the policies they validate.

## FR-5 Switchboard (phase 4)

- **FR-5.1** A local web UI shows the same inventory/health as `lab status` /
  `lab vm list`, reusing the same Python core (no logic duplication).
- **FR-5.2** The UI can run whitelisted tasks (start/stop VM, open tunnel,
  policy test) with the same guards as the CLI.
- **FR-5.3** Loopback-only listener, authenticated, secrets kept in `work/`.
