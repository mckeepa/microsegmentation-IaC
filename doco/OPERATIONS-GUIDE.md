# Configuration, Operation, and Maintenance Guide

## Status

This is the intended operating workflow, not yet an executable runbook. Component versions, CNI, storage, installation commands, and policy examples must be selected and tested before treating the steps as production instructions.

## Configure the Lab

1. Complete the [lab readiness checklist](LAB-SETUP.md), especially the 150 GiB storage target and `/dev/kvm` access check.
2. Record the Linux guest distribution, K3s/Kubernetes, KubeVirt, CNI, Argo CD, and client-tool versions in a version matrix. Use versions documented as compatible with one another.
3. Create an isolated QEMU/KVM guest with the approved CPU, RAM, and disk allocation. Confirm nested virtualization inside the guest before installing Kubernetes.
4. Install the single-node K3s cluster using the version-pinned procedure added after the component choices are made. Record the cluster endpoint and secure access method; never commit kubeconfig credentials.
5. Install the selected CNI and verify its policy enforcement path. Do not proceed based on pod-only policy tests if the goal is to isolate KubeVirt guests.
6. Install KubeVirt and its matching CLI version. Verify the operator and API report ready before creating a VM.
7. Configure the chosen storage class and import or create a disposable test VM image.
8. Install Argo CD and connect it to the approved repository path. Keep bootstrap resources separate from application policy resources.

## Configure and Apply a Policy

1. Define a dedicated test namespace, stable labels, one test workload, and the required DNS and management flows.
2. Add a default-deny ingress and egress baseline, then add the smallest explicit allow rules required for the test. Confirm the selected policy engine's semantics before relying on deny or priority behavior.
3. Open a change request containing the policy diff, expected allowed flows, expected denied flows, and rollback instructions.
4. Review selectors, ports, protocols, namespace scope, and any broad CIDR or wildcard match. Verify no secret or cluster credential is present.
5. Merge the reviewed change and let Argo CD reconcile it. Confirm the live resource matches the approved Git revision.
6. Run positive and negative connectivity tests from the VM guest and from any relevant pod. Capture the source, destination, protocol, port, result, and policy revision.
7. If any unexpected flow succeeds or required flow fails, revert the Git change, verify reconciliation, and repeat the test before proceeding.

Terraform must use separate state and approval workflows for Azure and NSX, and must not manage Kubernetes resources also owned by Argo CD. For Azure, review the VNet address plan, subnet/NSG associations, effective rule priority, default rules, subscription, region, and estimated cost before applying. Until Azure access, state storage, credentials, and budget controls exist, keep Azure at static validation/plan-only. Until NSX access, state storage, credentials, and approval controls exist, do not run an NSX `apply` or `destroy` workflow.

## Routine Health Checks

Use the Kubernetes client matching the pinned cluster version. These read-only checks are useful after bootstrap and during troubleshooting:

```sh
kubectl get nodes -o wide
kubectl get pods -A
kubectl get networkpolicy -A
kubectl get vmi -A
kubectl get kubevirt -n kubevirt
```

Confirm node readiness, system pod health, expected policy objects, VM instance state, and KubeVirt operator readiness. Also check host and guest disk consumption, available memory, and the age/status of the latest backup. Exact monitoring and alert thresholds are **TBD**.

## Maintenance

- Review and pin component upgrades before applying them; check K3s, Kubernetes, KubeVirt, CNI, and Argo CD compatibility as a set.
- Upgrade one layer at a time in the disposable lab and rerun the complete connectivity test matrix after each change.
- Keep policy and configuration changes in Git. Avoid manual cluster edits except for time-bounded diagnosis; reconcile or revert the Git source afterward.
- Back up Git remotely and define how to preserve or recreate VM disk data. A Git backup alone does not back up VM contents or Terraform state.
- Set a disk-growth threshold and remove unused images/snapshots only after confirming they are not needed for recovery.
- If NSX is later enabled, back up and secure Terraform state, review every plan, and define ownership boundaries before applying changes.

## Troubleshooting Sequence

1. Determine whether the issue is host virtualization, guest Kubernetes, CNI/policy, KubeVirt VM, storage, or GitOps reconciliation.
2. Check host free disk and memory first; a full filesystem can cause unrelated-looking cluster and VM failures.
3. Confirm the node and system pods are healthy before diagnosing a workload policy.
4. Compare the live policy and labels with the reviewed Git revision. Check selectors and namespace scope.
5. Test the same flow from a pod and from the VM guest to distinguish pod policy behavior from the KubeVirt guest network path.
6. Inspect the selected CNI's supported policy and logging mechanisms; do not infer enforcement from the presence of a NetworkPolicy object.
7. Revert the most recent policy or platform change if service restoration is needed, then record the observed failure and update the test matrix.

## Recovery Boundaries

The initial lab is disposable and has no defined recovery-time or recovery-point objective. Before storing useful VM data, document how to recreate the host guest, cluster, policy state, and VM disks from backups. Keep rollback instructions for each independently managed layer.