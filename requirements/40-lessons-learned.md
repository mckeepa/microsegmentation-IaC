# Lessons Learned from v1

Distilled from the `main` branch docs and scripts (paths below refer to `main`).
These are hard-won facts — the rebuild must not relearn them.

## Technical gotchas to preserve

- **OVN route loss on reboot.** The outer VM's default route can vanish after a
  restart; KubeVirt/CDI pods crash-loop with `network is unreachable`. Repair
  the route (guarded), then *wait* for CrashLoopBackOff timers (~5 min) to
  expire — do not delete pods. (`main`: scripts/20-install-k3s-kubevirt/repair-guest-network.sh)
- **OVN encap IP is baked to one DHCP lease.** `lab-k8s-01` had to keep
  192.168.122.123 via a libvirt DHCP host entry; any other lease crash-looped
  ovnkube-node. If keeping OVN, pin the lease at install time; better, pick a
  CNI without this failure mode (see constraints doc).
- **Only one CNI config may exist in `/etc/cni/net.d`.** A leftover podman
  bridge conflist captured pods that started before OVN was ready, landing them
  on a dead 10.88.0.0/16 network with broken DNS. Remove/disable competing CNI
  configs during cluster install.
- **Fresh cluster for custom CNI.** K3s must be installed with Flannel and its
  embedded network-policy controller disabled; disabling the controller later
  leaves stale iptables rules. Never switch CNI on an existing cluster.
- **`virtctl ssh --known-hosts` is ignored** by its local-ssh wrapper; every
  connection must also pass `--local-ssh-opts '-o UserKnownHostsFile=<file>'`
  to actually pin host keys.
- **Masquerade guest MACs change every VM restart** (derived from the launcher
  pod IP). Guest network config must match NICs by name (`en*`), never by MAC —
  a MAC-pinned netplan leaves the VMI Running but with no IPv4 and SSH refused.
- **Masquerade addressing:** a guest sees itself as 10.0.2.2; other workloads
  reach it via the launcher pod IP, and only ports declared on the VM spec are
  forwarded. `lab vm list`'s PORTS column must be treated as authoritative.
- **CDI uploads need a two-hop tunnel** (in-cluster port-forward to
  cdi-uploadproxy + SSH -L to host loopback), with both ends tracked and
  cleaned up. Existing PVCs may need
  `cdi.kubevirt.io/storage.bind.immediate.requested=true`.
- **A NetworkPolicy object proves nothing.** Pod-level probes don't demonstrate
  guest enforcement; test allowed *and* denied flows with real guest-originated
  traffic and record the result matrix (this drove FR-4.2).
- **Storage is one disk.** All nested PVCs are local-path on the outer VM;
  check free space before imports/starts; never `qemu-img resize` an active
  disk (use libvirt blockresize + guest-agent FS growth).
- **DHCP leases change after restarts** — rediscover the outer VM IP every
  time (lease first, QEMU guest agent fallback); never cache it.
- **SSH tunnels are not boot services.** Every dashboard/RDP tunnel must be
  reopened after a host or VM restart; `lab up` owns this.

## What worked well (keep these patterns)

- **Ownership markers** on VMs/resources; refuse to touch same-named unmanaged
  resources. (v2: FR-1.5)
- **Gitignored `work/`** for keys, per-target known-hosts files, cached
  checksummed images, kubeconfig; symlink refusal on key material.
- **Idempotent, resumable operations** with dry-run/verify/status modes.
- **Explicit guards on destructive/repair actions**; preserve disks when
  recovering failed launchers.
- **Heartbeat wait loops** reporting elapsed time, phase, and the *real* last
  error (virtctl buries it under `exit status N` noise — filter for it).
- **One shared plumbing library** instead of per-script SSH/retry/tunnel logic.

## What caused the mess (avoid these)

- Numbered task-folder sprawl (00–90) with no single entry point; choosing the
  right script required reading a 141-line README.
- Unclear first-build vs. resume paths; creators run against existing labs.
- Bash complexity: retry/tunnel/SSH logic repeated until belatedly extracted.
- Per-OS setup scripts duplicating behavior (Ubuntu/Rocky/Windows/desktop/fleet
  each had their own); fixes like host-key handling missed some copies.
- Docs restating live state → drift; handoff docs mixing history with current
  inventory.
- Test tooling not updated when resources changed; policy testing stayed manual.
- Too many concerns (tests, desktops, dashboards, portal) sharing one
  single-node lab's RAM/disk/attention.
