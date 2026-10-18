# Verify Kubernetes Isolation

Return to the [project README](../../README.md) and review the [policy architecture](../../doco/ARCHITECTURE.md) before testing. Kubernetes isolation is the primary runtime validation target.

## Test VMs

Create disposable KubeVirt guests inside `lab-k8s-01`:

- `netpol-client` (Ubuntu Server 24.04.5): initiates connections.
- `netpol-server-rocky` (Rocky Linux 10.2): exposes a test service on a documented TCP port.
- `netpol-server-windows` (Windows Server 2025 Evaluation): a second server target, tested in a separate run.

If you want to test actual RHEL instead of a compatible rebuild, use the no-cost Red Hat Individual Developer Subscription only if its current individual/home-lab terms apply. Substitute it for `netpol-server-rocky`; do not add another concurrently running VM to the initial resource budget.

Use the resource sizing from the [lab VM inventory](../../doco/LAB-SETUP.md). Do not create these guests in Virtual Machine Manager; they are KubeVirt workloads. Keep the Windows guest powered off during the Rocky test and vice versa. Windows evaluation media is not a production license; attach the KubeVirt `virtio-win` driver disk and install the matching storage/network drivers. Confirm Windows Server 2025 support against the pinned KubeVirt version before the run.

Before creating the VMIs, complete [task 25: prepare guest images](../25-prepare-guest-images/README.md). The Ubuntu and Rocky media are downloaded and checksum-verified by scripts. The Windows Evaluation ISO is obtained interactively from Microsoft and staged by the helper script; do not automate past Microsoft's evaluation terms. The method to import each ISO into KubeVirt storage is **TBD** until the cluster storage class and CDI/upload approach are selected.

## Steps

1. Record the CNI, KubeVirt binding mode, network attachment, storage class, VM labels, namespace labels, and guest IPs used for the run.
2. Create a dedicated namespace with stable labels. Start `netpol-server-rocky` from the Rocky 10 guest image with a single test service; later repeat the same policy cases against `netpol-server-windows` using the Windows Server evaluation image.
3. Verify baseline connectivity before applying policy so that routing and service startup are known-good.
4. Apply explicit default-deny ingress and egress policies. Remember that standard NetworkPolicy treats ingress and egress isolation independently and combines matching allows additively.
5. Add only the intended DNS and client-to-server allow rules. Avoid broad CIDR, namespace, or port allowances unless they are part of the test case.
6. From `netpol-client`, verify the approved connection to the Rocky guest succeeds and record protocol, destination, port, and result.
7. Test an unapproved port, destination, and direction; each must fail. Include pod-to-VM and VM-to-VM tests if both paths are in scope.
8. Repeat the tests after policy reconciliation and after restarting the VMIs. Verify actual packet behavior; the presence of a NetworkPolicy object alone does not prove enforcement.
9. Remove one allow rule, reconcile, and confirm the formerly allowed new connection is denied. Restore the approved policy afterward.
10. Repeat the same allow/deny matrix against the Windows Server guest. Record VirtIO driver versions and any OS-specific setup differences.
11. Save test output with the Git revision, guest OS versions, component versions, and any CNI/KubeVirt-specific exceptions.

If pod traffic is isolated but guest traffic is not, treat that as a failed KubeVirt network-path test. Do not claim VM isolation until the selected binding mode and CNI enforce the expected behavior for guest-originated and guest-destined traffic.