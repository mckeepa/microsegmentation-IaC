# Microsegmentation Policy-as-Code Plan

This folder holds the long-lived design and future code for the policy plane. It is separate from the disposable lab setup so the policy contract survives after the PoC.

## Current State

- Lab infrastructure is implemented and checked by the task guides. The outer VM, K3s, OVN-Kubernetes, KubeVirt, CDI, and dashboards are deployed.
- Rocky 10 and the Ubuntu client are installed and verified. Windows is still being set up; the account/credential state is unverified.
- No shared policy intent, policy compiler, or platform adapter exists yet.
- Azure NSG/VNet and NSX are designed targets, not deployed.

## Goals

1. Define one reviewed policy intent per application/flow.
2. Render that intent to Kubernetes NetworkPolicy for VM and pod traffic, Azure NSG rules for a VNet, and NSX DFW policy.
3. Keep the outputs comparable so the same intent can be checked for capability and safety before any apply.
4. Record evidence with each change so the policy can be audited later.

## Non-Goals for the PoC

- No NSX or Azure deployment yet.
- No claim of identical platform behavior.
- No production HA, DR, or migration tooling.

## Scope of the Initial Contract

- L3/L4 allow/deny only.
- Named identities for source and destination, resolved per platform.
- Explicit ingress and egress direction.
- Default-deny baseline and narrow allow rules.
- DNS and management flows called out separately.

## Change and Audit Mapping

Every policy revision must record a change record. The policy file is version-controlled; a matching change record entry should include:

- Change ID
- Requestor / approver
- Summary and reason
- Planned start/end times
- Actual deployment time
- Rollback plan and result
- Affected platforms
- Link to the Git commit or tag used for the change

The change record is audit metadata, not infrastructure code. It should live beside the policy intent (for example, a `changes/` file or a reviewed tracking sheet), and the deployment should reference the current change ID so a report can show which rules changed and when.

## Diff and Reportability

The policy plane must be diffable from Git:

- Keep the policy intent in a stable, human-readable format.
- Keep rendered outputs deterministic.
- Run `git diff` or `git show` to answer "what changed this week" for the policy contract and its rendered output.
- Record the Git revision in test evidence so a report can be tied to a specific change.

## Platform Adapters

- **Kubernetes:** render `NetworkPolicy` for the pod/VM path used in the lab. Validate that the CNI actually enforces the policy; do not assume applying a manifest is proof.
- **Azure:** render VNet/subnet/NSG resources with explicit priority and association scope. Account for built-in default rules and validate effective rules before claiming enforcement.
- **VMware NSX:** render groups, services, and policies for the NSX Policy API. Validate statically; runtime realization is required when a licensed manager is available.

## Delivery Shape

- Git remains the source of truth for policy intent and rendered output.
- Argo CD is the planned reconciler for Kubernetes resources; direct `kubectl` is acceptable only for bootstrap validation.
- Terraform owns Azure and NSX with separate state and approval gates.

## Safety Rules

- Fail closed when a platform cannot represent the intended policy.
- Never weaken a rule silently.
- Do not mix ownership of the same object between Argo CD and Terraform.
- Keep secrets out of Git and out of policy files.
