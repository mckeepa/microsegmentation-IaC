# Constraints and Environment

## Host

- Physical Linux laptop with KVM/libvirt (`qemu:///system`), `virsh`,
  `virt-install`, `ssh`, `curl` available. Single machine; no second host.
- Lab networking stays on libvirt NAT (`default` network). Nothing is exposed
  beyond the laptop; management listeners bind loopback only.

## Known-good version baseline (v1, starting point for v2 pins)

| Component | Version |
| --- | --- |
| Outer VM OS | Ubuntu Server 24.04 LTS |
| K3s | v1.36.5+k3s1 |
| CNI | **Cilium** (v2 decision — pin latest stable in `versions.py`); v1 used OVN-Kubernetes v1.4.0 |
| KubeVirt / virtctl | v1.9.1 |
| CDI | v1.66.1 |
| Helm | v3.22.1 |

**CNI decision: Cilium.** v1's OVN-Kubernetes caused the worst operational
pain (route loss on reboot, encap IP pinned to one DHCP lease, CNI config
conflicts). v2 uses Cilium: it enforces standard NetworkPolicy (FR-4) and its
CiliumNetworkPolicy adds Layer 7 inspection and rules (HTTP methods/paths,
DNS) as a future capability. K3s must still be installed with Flannel and the
embedded network-policy controller disabled; a CNI change requires a fresh
cluster — never switch in place.

## Existing lab

- The v1 lab (`lab-k8s-01` outer VM and its nested guests) keeps running from
  `main` until v2 phase 2 is usable; then it is torn down and rebuilt with v2
  tooling. v2 must not adopt or mutate v1-created resources.
- `work/` is shared and gitignored; v2 may reuse cached ISOs/images (checksum
  verified) but must generate its own keys and state under distinct names.

## Non-negotiable ground rules (carried from v1)

- Key-only SSH everywhere; guest access tunnels through the Kubernetes API.
- No secrets in git, ever.
- Ownership markers on everything the tooling may mutate.
