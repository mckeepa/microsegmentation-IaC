# Lab Setup and Prerequisites

## Host Snapshot

Observed on the development host on 2026-10-18:

| Resource | Observed | Assessment |
| --- | --- | --- |
| CPU | Intel Core i7-1360P, 16 logical CPUs | Suitable for a small single-node lab; leave capacity for the host |
| Memory | 62 GiB total, about 47 GiB available at check time | Suitable for a moderate nested lab; do not allocate all available memory |
| KVM | `/dev/kvm` exists; `kvm_intel` is loaded | Host virtualization is present; verify the current account can read and write `/dev/kvm` |
| Nested virtualization | `/sys/module/kvm_intel/parameters/nested` reports `Y` | Enabled on the host; verify virtualization is exposed inside the lab guest |
| Root filesystem | 3.6 TiB total, 461 GiB free (87% used) | Above the 150 GiB planning target; monitor growth |

These are a point-in-time snapshot, not a guarantee of capacity. Confirm current free memory and disk before provisioning.

## Capacity Recommendation

Free or attach storage so that **at least 150 GiB is available** on the filesystem that will contain the outer lab VM and its disk images before starting. This is a practical planning target for one nested K3s/KubeVirt lab with a small number of test images, not a vendor minimum. **100 GiB free is a tight floor** for a deliberately small experiment. Plan for **200 GiB or more** if keeping snapshots or running several VM workloads.

The latest check found 461 GiB free on the root filesystem, exceeding the 150 GiB target by about 311 GiB. The root filesystem is backed by the host's 3.6 TiB NVMe through LVM; no separate VM-storage filesystem was listed. Recheck before provisioning, since a dynamically allocated QCOW2 disk can grow toward its configured maximum and snapshots can consume substantial space.

## Provisional Lab Guest Sizing

Use these only as initial planning values; adjust after a smoke test and record actual consumption:

| Guest allocation | Initial planning value |
| --- | --- |
| vCPU | 8 virtual CPUs |
| RAM | 24 GiB |
| Guest disk | 100 GiB virtual capacity, dynamically allocated if supported |
| Topology | One Linux guest running a single-node K3s cluster |

The guest disk must hold the operating system, Kubernetes and KubeVirt images, manifests, logs, and test VM disk data. Keep the guest and nested workload disposable until a backup strategy exists. Do not enable host memory overcommit as a substitute for capacity planning.

## VM Inventory

Use this topology for the first lab. The guest OS test targets are started sequentially so their memory allocations do not compete unnecessarily with the single-node cluster:

| VM | Runs on | Purpose | Provisional allocation |
| --- | --- | --- | --- |
| `lab-k8s-01` | Host QEMU/KVM via Virtual Machine Manager | Single-node K3s server/worker, CNI, KubeVirt, and Argo CD | 8 vCPU, 24 GiB RAM, 100 GiB dynamically allocated disk |
| `netpol-client` | KubeVirt inside `lab-k8s-01` | Linux client that initiates allowed and denied test connections | 2 vCPU, 2 GiB RAM, 10 GiB disk; Ubuntu Server 24.04.5 |
| `netpol-server-rocky` | KubeVirt inside `lab-k8s-01` | RHEL-compatible Linux server for policy tests | 2 vCPU, 2 GiB RAM, 10 GiB disk; Rocky Linux 10.2 |
| `netpol-server-windows` | KubeVirt inside `lab-k8s-01` | Windows guest policy target, tested separately from the Linux server | 2 vCPU, 4 GiB RAM, 40 GiB disk; Windows Server 2025 Evaluation |

`lab-k8s-01` is the only VM to create in Virtual Machine Manager initially. All three test guests are Kubernetes/KubeVirt resources, not additional host VMs. Keep `netpol-client` running and start only one server guest at a time. The Windows allocation is a planning value, not a Microsoft minimum or a confirmed KubeVirt sizing requirement.

Use Rocky Linux when the test needs a RHEL-compatible userland; it is a community rebuild, not Red Hat Enterprise Linux itself and does not substitute for a Red Hat subscription or certification test. For an exact RHEL guest, Red Hat offers a no-cost Individual Developer Subscription for eligible personal development/testing use (self-supported, up to 16 systems); review the current terms and use it only if the individual/home-lab conditions fit. It can replace the Rocky guest for that test, not run concurrently in the initial resource budget. Windows Server 2025 is an evaluation-only guest unless separately licensed. Obtain it from Microsoft's official Evaluation Center and follow its current evaluation terms. Do not use evaluation media for production.

KubeVirt's Windows guide requires VirtIO drivers for paravirtualized disk and network devices and describes attaching the `virtio-win` driver disk during installation. Validate the Server 2025 installer, selected KubeVirt release, boot firmware, storage, network driver, and NetworkPolicy path before treating this as a supported test target. Store all ISOs and temporary installation media under the ignored root `work/` directory.

Ubuntu 24.04.5 is the latest point release in the 24.04 LTS series, but not the latest Ubuntu release. As of 2026-10-18, Ubuntu 26.04.1 is the latest LTS and 26.10 is the latest overall release. Keep 24.04.5 for this initial K3s host baseline until the selected K3s/KubeVirt/CNI combination is verified on 26.04; do not equate “latest” with “best validated baseline.”

Do not create separate K3s control-plane and worker VMs for the first proof of concept. Add a second K3s node only if later tests specifically require cross-node policy behavior. VMware NSX Manager and Azure appliances are not part of this local VM inventory; NSX requires an authorized VMware environment, and Azure networking is a cloud deployment rather than a local VM.

Follow the task guides in [scripts/README.md](../scripts/README.md), starting with [host preflight](../scripts/00-host-preflight/README.md) and [creating the lab VM](../scripts/10-create-lab-vm/README.md). After K3s/KubeVirt installation, run [task 25 to prepare Ubuntu, Rocky, and Windows guest images](../scripts/25-prepare-guest-images/README.md) before beginning [isolation verification](../scripts/30-verify-kubernetes-isolation/README.md).

## Required Decisions Before Installation

- Linux guest distribution and supported version.
- K3s, Kubernetes API, KubeVirt, `virtctl`, CNI, and Argo CD versions; pin versions together after compatibility checks.
- CNI and policy engine. Evaluate upstream OVN-Kubernetes first for closer OpenShift alignment; verify it works with the pinned K3s/Kubernetes and KubeVirt versions. Use K3s's bundled Flannel only as an explicitly lower-fidelity fallback, and validate NetworkPolicy enforcement on actual KubeVirt guest traffic.
- KubeVirt interface binding and storage class, validated against the selected CNI and workload.
- Isolated guest network design, API access method, DNS, address ranges, and outbound access.
- Test VM image, workload, permitted flows, denied flows, and how each result will be observed.
- Windows Server evaluation access/terms and KubeVirt VirtIO driver compatibility; Rocky Linux release to test.
- Secret handling and backup location for cluster configuration, VM definitions, and VM disk data.

## Readiness Checklist

- [ ] At least 150 GiB free on the intended VM storage filesystem, or equivalent capacity on a separate disk.
- [ ] The current user can read and write `/dev/kvm` without relying on an unreviewed permission workaround.
- [ ] A test guest can see CPU virtualization flags (`vmx` for this Intel host) and access KVM.
- [ ] Host CPU, memory, and storage allocations leave an adequate margin for the Linux desktop and other workloads.
- [ ] The lab network is isolated and does not overlap with the host LAN, VPN, or other routed networks.
- [ ] Component versions and installation sources are pinned in the project before the first reproducible build.
- [ ] VM image and cluster data locations are known, with cleanup and recovery expectations documented.

## VMware NSX

NSX is not a prerequisite for the K3s/KubeVirt proof of concept. The project currently has no VMware license, so NSX provider configuration, API compatibility, and firewall behavior cannot be tested. Keep NSX integration disabled until an authorized, supported NSX environment is available.

## Guest Image References

- [Ubuntu 24.04 releases](https://releases.ubuntu.com/24.04/) and [Ubuntu 26.04 releases](https://releases.ubuntu.com/26.04/).
- [Rocky Linux downloads](https://rockylinux.org/download). Use Rocky Linux 10.2 as the initial RHEL-compatible guest candidate.
- [Red Hat no-cost Individual Developer Subscription FAQ](https://developers.redhat.com/articles/faqs-no-cost-red-hat-enterprise-linux): optional route to test actual RHEL under the individual developer/home-lab terms.
- [Windows Server 2025 Evaluation Center](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025). Evaluation media is subject to Microsoft's current terms and may require account sign-in.
- [KubeVirt Windows VirtIO drivers](https://kubevirt.io/user-guide/user_workloads/windows_virtio_drivers/).
- [K3s host requirements](https://docs.k3s.io/installation/requirements): K3s is expected to work on most modern Linux systems; verify the full selected component combination in the lab.