# KVM Microsegmentation Lab

This project plans and validates a policy-as-code approach to network microsegmentation across VMware NSX, Kubernetes workloads, and Azure Virtual Networks (VNets) with Network Security Groups (NSGs). The first milestone is a small K3s and KubeVirt proof of concept on the existing QEMU/KVM host. OpenShift Virtualization is the preferred longer-term Kubernetes target. NSX and Azure are separate infrastructure backends driven from shared policy intent, not from identical platform resources.

The project is intended to test how workload identity, default-deny policy, explicitly allowed traffic, policy delivery, and validation can be managed consistently. Kubernetes isolation is the primary runtime proof of concept; NSX and Azure implementations also require provider/static checks and platform-specific validation. The project does not claim that the three policy engines behave identically.

## Project Status

Documentation and design planning. No installable IaC modules or tested deployment automation are present yet. Host checks found 16 logical CPUs, 62 GiB RAM, Intel nested virtualization enabled, and `/dev/kvm` present. The latest storage check found 461 GiB free on the root filesystem, above the 150 GiB planning target; see the [lab setup](doco/LAB-SETUP.md) before creating VMs.

## Documentation

- [Documentation index](doco/README.md)
- [Architecture](doco/ARCHITECTURE.md)
- [High-level design](doco/HIGH-LEVEL-DESIGN.md)
- [Lab setup and prerequisites](doco/LAB-SETUP.md)
- [Configuration, operation, and maintenance guide](doco/OPERATIONS-GUIDE.md)
- [Project plan and open decisions](doco/PROJECT-PLAN.md)
- [Task-by-task setup guides and scripts](scripts/README.md)
- [Original source material](doco/orginal/)

## Intended Delivery Model

- A version-controlled policy definition is the shared source of intent, with platform-specific validation and outputs.
- Argo CD is the proposed reconciler for Kubernetes resources.
- Terraform with separate provider configurations and state manages Azure VNets/NSGs and NSX resources; NSX requires a supported, licensed, reachable environment.
- A policy compiler/adapter must reject unsupported semantics rather than silently weakening a policy. Exact cross-platform equivalence is not assumed.

## Current Constraints

- The host is QEMU/KVM-based and there is no VMware license, so NSX resources cannot currently be deployed or runtime-validated.
- Azure deployment requires an Azure subscription, permissions, cost controls, and a selected region; these are not yet confirmed.
- The K3s CNI is not installed yet. Upstream OVN-Kubernetes is the first candidate to better align isolation testing with OpenShift; K3s compatibility must be verified before installation. Bundled Flannel is a documented lower-fidelity fallback.
- Disk capacity currently exceeds the lab planning target; monitor free space as VM images and snapshots grow.
- Versions, storage, lab networking, VM workload, and acceptance criteria remain to be confirmed. The documentation marks these as decisions rather than presenting untested commands as a working procedure.

## Scope

The initial scope is a single-node, disposable K3s/KubeVirt lab that demonstrates policy behavior, Git-based changes, and repeatable validation across Ubuntu, a RHEL-compatible Rocky Linux guest, and a Windows Server evaluation guest. The design includes independently generated NSX, Kubernetes, and Azure targets. High availability, production operations, migration tooling, and claims of behaviorally identical enforcement are out of scope.

## Lab VM Plan

Start with one outer QEMU/KVM guest for K3s and KubeVirt, then create two small test VMs inside KubeVirt for client/server isolation tests. See the [lab setup guide](doco/LAB-SETUP.md) and the [setup task guides](scripts/README.md). Do not create separate K3s control-plane and worker VMs for the initial proof of concept.