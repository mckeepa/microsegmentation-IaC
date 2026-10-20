# Project Plan and Open Decisions

This is the target roadmap. Local infrastructure and Linux access are implemented; isolation evidence, Windows installation, and cross-platform policy delivery remain incomplete. For completed tasks and runnable next steps, use the [implementation checkpoint](IMPLEMENTATION-STATUS.md), not the phase table alone.

## Agreed Direction

- Build a rapid proof of concept on the current Linux workstation using QEMU/KVM.
- Start with K3s if that is the fastest workable route; keep OpenShift Virtualization as the preferred longer-term target.
- Use one reviewed policy intent for VMware NSX, Kubernetes isolation, and Azure VNets/NSGs, with platform-specific adapters and validation.
- Use GitOps for Kubernetes resources and separate Terraform state/provider workflows for Azure and NSX.
- VMware licensing is not available, so NSX runtime deployment cannot be a gate for the initial proof of concept; static adapter checks remain in scope.
- Azure is a required target; subscription, region, budget, and access are not yet confirmed.
- Historical host snapshot (2026-10-18): 16 logical CPUs, 62 GiB RAM, nested Intel virtualization enabled, `/dev/kvm` present, and 461 GiB free on the root filesystem. Rerun preflight for current capacity.
- Plan for 150 GiB free on the filesystem used for VM storage before building the lab.

## Phased Plan

| Phase | Work | Exit criteria |
| --- | --- | --- |
| 0. Decisions and readiness | Define common policy contract, platform capability rules, versions, CNI, storage, Azure scope/budget, network models, test workload, and policy cases | First-build decisions recorded; required Azure access confirmed or marked plan-only; host checklist passes |
| 1. Repeatable KVM guest | Create and document the nested-virtualization guest and secure access | Guest can use KVM, has recorded resource allocation, and can be recreated from documented steps |
| 2. K3s and KubeVirt | Install pinned components and a disposable VM | Cluster and operator are healthy; test VM starts and guest traffic path is known |
| 3. Kubernetes isolation proof | Implement default-deny and explicit allows; test allowed and denied pod and KubeVirt guest traffic | Results are repeatable, observable, and tied to policy revision; CNI behavior and limitations recorded |
| 4. Azure adapter | Render VNet/subnet/NSG resources; statically validate, plan, and deploy a minimal isolated VNet if authorized | NSG rules account for priority/defaults; effective rules and allowed/denied traffic are verified or deployment remains explicitly unverified |
| 5. GitOps and IaC operations | Add Argo CD reconciliation, separate Terraform state/workflows, approvals, rollback, and maintenance steps | Reviewed changes reconcile/apply independently and can be reverted; ownership and cost controls are clear |
| 6. OpenShift comparison | Compare policy APIs and enforcement behavior against a supported OpenShift Virtualization environment | Compatibility gaps and migration requirements documented; no unsupported equivalence claims |
| 7. NSX backend verification | If licensed access is obtained, validate the NSX provider output, plan/apply, realization, and traffic behavior | Static checks always recorded; runtime deployment and enforcement verified when an NSX environment is available |

## Decision Register

| Decision | Why it matters | Current status |
| --- | --- | --- |
| CNI and policy engine for K3s | Controls enforcement semantics and compatibility with KubeVirt guest traffic | Upstream OVN-Kubernetes installed; configuration/health checked; guest isolation evidence pending |
| Flannel fallback | Provides a simpler route to test NetworkPolicy semantics if upstream OVN-Kubernetes cannot be made supportable | Explicit lower-fidelity fallback; results must not be reported as OpenShift dataplane parity |
| OpenShift dataplane parity | Red Hat packages and manages OVN-Kubernetes as part of the platform; upstream OVN on K3s cannot verify all OpenShift integration/features | Document the boundary; validate exact platform behavior later if an OpenShift cluster is available |
| Kubernetes/K3s and KubeVirt versions | Determines API support and component compatibility | Versions are pinned and checked by task 20; review the complete set before upgrades |
| Guest distribution and VM sizing | Determines nested virtualization, resource use, and repeatability | Ubuntu outer VM/client, Rocky 10 test server, Windows 2025 Evaluation; optional separate Rocky 9 desktop; allocations in lab setup |
| Guest OS validation matrix | Confirms policy behavior is not accidentally specific to one guest OS | Ubuntu client, Rocky Linux 10.2 server, Windows Server 2025 Evaluation server; Windows compatibility and evaluation access to confirm |
| KubeVirt binding mode | Changes the guest network path and where policy is enforced | Pod network with masquerade selected; ingress/egress policy testing pending |
| Storage backend and disk layout | VM image growth is the immediate host constraint | local-path selected; outer disk expanded to 130 GiB; no HA/migration claim |
| KubeVirt image import | Determines how Ubuntu/Rocky/Windows media and disk images become PVCs | CDI plus `virtctl image-upload` implemented; Ubuntu and desktop cloud-image paths verified |
| Lab network and address plan | Prevents conflicts and controls access to the cluster | Local libvirt NAT/OVN baseline documented in task 20; cloud/routed network design remains open |
| Test workload and policy cases | Makes success measurable rather than subjective | Open; choose one simple client/server flow and required infrastructure flows |
| Policy source format | Affects review and cross-platform behavior | Shared policy intent is required; render Kubernetes manifests and separate Azure/NSX Terraform outputs |
| Shared policy contract and adapter behavior | Determines whether all three targets express the same intent without unsafe semantic loss | Required; define a portable L3/L4 baseline and explicit capability failures |
| Azure subscription, region, budget, and permissions | Required to deploy and verify VNets and NSGs; cloud resources can incur charges | Open; Azure static validation can proceed without credentials, runtime claims cannot |
| Azure VNet/subnet/NSG association model | Determines traffic scope and whether identities can map to NICs/ASGs or CIDRs | Open; NSGs associate to subnet or NIC, not directly to VNet |
| Azure rule priority and built-in default behavior | Can make apparent default-deny policies ineffective if defaults are not overridden | Open; encode explicit higher-priority exceptions and deny rules, then inspect effective rules |
| Argo CD bootstrap and repository layout | Defines when/how GitOps becomes authoritative | Defer until after first policy smoke test; use reviewed direct `kubectl` apply for bootstrap validation |
| Secret and state management | Required before external infrastructure automation | Open; no credentials or state in Git |
| Logging, metrics, and recovery goals | Needed to diagnose and maintain the system | Open; not required for first smoke test, required before operational handoff |
| OpenShift target version and access | Required to verify the future platform mapping | Open; no target cluster confirmed |

## Not in the First Proof of Concept

- Production high availability, multi-node failure recovery, or performance certification.
- Behaviorally identical policy enforcement across NSX, Kubernetes, and Azure.
- NSX apply/destroy workflows without a licensed, accessible environment.
- VM migration automation or a claim of zero-downtime migration.
- A claim that Kubernetes NetworkPolicy, NSX DFW, OpenShift administrative policies, and Azure NSGs have identical precedence or behavior.

## Definition of Done for the First Proof of Concept

- The host has sufficient free storage and the nested guest can use KVM.
- A pinned, documented K3s/KubeVirt lab can be recreated.
- The selected CNI enforces the intended policy on VM guest traffic, verified with both allowed and denied connection tests.
- Azure policy intent renders to valid VNet/NSG infrastructure and accounts for Azure NSG rule ordering and defaults; runtime verification is required before claiming Azure enforcement.
- The NSX policy adapter passes static checks and provider planning; runtime enforcement is claimed only when verified against a licensed NSX manager.
- GitOps applies a reviewed policy change and can revert it successfully.
- Resource use, troubleshooting observations, limitations, and next OpenShift validation steps are recorded.