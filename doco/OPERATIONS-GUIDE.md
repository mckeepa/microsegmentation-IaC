# Configuration, Operation, and Maintenance Guide

## Status

Use the linked task guides for implemented lab commands and the [checkpoint](IMPLEMENTATION-STATUS.md) for the last verified state. The local cluster, Linux guests, optional desktop, and dashboards have tested procedures. Policy enforcement tests, Argo CD delivery, and Azure/NSX adapters remain planned or incomplete. Nothing here is a production runbook.

## Configure the Lab

1. Complete the [lab readiness checklist](LAB-SETUP.md), especially the 150 GiB storage target and `/dev/kvm` access check.
2. Follow [tasks 10 and 20](../scripts/README.md#task-guides) for the managed outer VM and pinned K3s/OVN/KubeVirt/CDI bootstrap. Do not reinstall an existing lab just to resume work.
3. Follow [task 25](../scripts/25-prepare-guest-images/README.md) for media and [task 30](../scripts/30-create-kubevirt-vms/README.md) for first-time test-VM creation, Rocky installation, and JSON-configured Ubuntu setup. Do not reapply manual installer templates to installed guests.
4. Use [task 32](../scripts/32-rocky-desktop/README.md) only for the optional, separate Rocky desktop; it is not a policy-test server.
5. Use [task 45](../scripts/45-monitoring-dashboard/README.md) for optional monitoring dashboards.
6. Configure guest test services and use the [task 35 plan](../scripts/35-verify-kubernetes-isolation/README.md) before claiming isolation. Its legacy runner is not compatible with the current task 30 resources.
7. Defer Argo CD until the first reviewed policy smoke test works. Its installation and reconciliation workflow are not implemented here.

## Configure and Apply a Policy

The following is the intended reviewed GitOps process, not a currently automated workflow. Until Argo CD is installed, bootstrap tests require reviewed direct Kubernetes changes and the task 35 prerequisites. Do not expect a Git merge alone to deploy policy.

1. Define a dedicated test namespace, stable labels, one test workload, and the required DNS and management flows.
2. Add a default-deny ingress and egress baseline, then add the smallest explicit allow rules required for the test. Confirm the selected policy engine's semantics before relying on deny or priority behavior.
3. Open a change request containing the policy diff, expected allowed flows, expected denied flows, and rollback instructions.
4. Review selectors, ports, protocols, namespace scope, and any broad CIDR or wildcard match. Verify no secret or cluster credential is present.
5. Merge the reviewed change and let Argo CD reconcile it. Confirm the live resource matches the approved Git revision.
6. Run positive and negative connectivity tests from the VM guest and from any relevant pod. Capture the source, destination, protocol, port, result, and policy revision.
7. If any unexpected flow succeeds or required flow fails, revert the Git change, verify reconciliation, and repeat the test before proceeding.

Terraform must use separate state and approval workflows for Azure and NSX, and must not manage Kubernetes resources also owned by Argo CD. For Azure, review the VNet address plan, subnet/NSG associations, effective rule priority, default rules, subscription, region, and estimated cost before applying. Until Azure access, state storage, credentials, and budget controls exist, keep Azure at static validation/plan-only. Until NSX access, state storage, credentials, and approval controls exist, do not run an NSX `apply` or `destroy` workflow.

## Routine Health Checks

For the full inventory of monitoring tools and optional Cockpit/Headlamp web dashboards, see [Monitoring and dashboards](MONITORING.md). The [task 45 runbook](../scripts/45-monitoring-dashboard/README.md) covers installation, SSH access from a laptop, and verified read-only/admin switching.

From the physical host at the repository root, run:

```sh
bash scripts/check-lab-progress.sh
bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh
```

The progress checker can start the outer VM with approval; it does not start nested guests. The cluster checker may attempt the documented guarded network repair if SSH is unavailable. For resource-only queries, first use `bash scripts/10-create-lab-vm/login-lab-vm.sh` to log into the **outer VM**, then run:

```sh
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
sudo k3s kubectl get networkpolicy -A
sudo k3s kubectl get vmi -A
sudo k3s kubectl get kubevirt -n kubevirt
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