# Implementation Status

Last checked: 2026-10-19

This is the durable project checkpoint. Run `bash scripts/check-lab-progress.sh` for a fresh, read-only inventory before resuming; live state may have changed since this note was written.

## Completed

- Host preflight passed: 16 logical CPUs, KVM access and nested virtualization enabled; host root filesystem had about 431 GiB free at last check.
- The managed outer VM `lab-k8s-01` is running. Its QCOW2 virtual disk was expanded online from 100 GiB to 130 GiB; Ubuntu partition, LVM, and root filesystem growth completed successfully.
- The task 20 K3s/OVN/KubeVirt/CDI health check passed. When the libvirt DHCP lease expired, the QEMU guest agent still reported the OVN bridge address; the SSH recovery restored the default route. The checker and diagnostics now use a non-link-local guest-agent address when no DHCP lease is available.
- Task 25 media is staged and has been uploaded to Kubernetes: Rocky Linux 10, Ubuntu Server 24.04.5, and Windows Server 2025 Evaluation.

## Current Task 30 State

- Namespace `netpol-test` exists and is labeled `microsegmentation-iac` as its manager.
- Rocky server `netpol-server-rocky` and Ubuntu client `netpol-client` VM resources exist. Both reached VMI `Running` during the boot check and are now stopped. Their installer PVCs and blank disk PVCs are bound.
- Windows server `netpol-server-windows` exists, but its VMI is `Pending`; task 30 has **not** completed.
- The Windows launcher pod failed to pull `quay.io/kubevirt/virtio-container-disk:latest`. The recorded failure is that containerd 2.3 rejects the image's Docker schema-1 manifest (`application/vnd.docker.distribution.manifest.v1+prettyjws`). The Windows VM template needs a schema-2/OCI-compatible VirtIO driver media source before its boot check can pass.
- The prior Windows blank-disk DataVolume remains `PVCBound` under `WaitForFirstConsumer`. The current local task 30 script has been changed to create plain PVCs and mount them directly, but this revised path has not yet been validated end to end. Existing resources are preserved; do not delete the namespace to retry.
- Guest `/` had about 90 GiB free after disk expansion, above task 30's 84 GiB guard.

## Resume Order

1. Run `bash scripts/check-lab-progress.sh` and review its recommendation.
2. Update the Windows VirtIO driver disk image reference in `scripts/30-create-kubevirt-vms/create-test-vms.sh` to a compatible OCI/schema-2 source. Keep the official evaluation ISO and manual licensing/driver installation requirements unchanged.
3. Validate the task 30 script, then rerun it. It should resume only recognized project resources; it must not delete existing disks or installer PVCs.
4. Confirm Rocky, Ubuntu, and Windows each have a successful VMI boot check and are stopped afterward.
5. Install each guest OS interactively from its printed `virtctl start`/`virtctl vnc` commands. Windows Evaluation terms and VirtIO driver selection remain manual.
6. Continue to task 35 only after guest OS installation and configuration. The legacy `run-isolation-test.sh` is not a follow-on to task 30 and should not be run against these resources.

## Recovery Notes

- For missing SSH after a lease expires, use `scripts/20-install-k3s-kubevirt/repair-guest-network.sh --diagnose`; the cluster checker also attempts the guarded runtime repair. It is not persistent across reboot.
- To expand the outer VM disk, use `bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh <total-size-gib>`. Do not run `qemu-img resize` against the active disk.
- Task 30 failures may leave PVCs, DataVolumes, VMs, or VMIs behind. The creator intentionally preserves them. Inspect the live state and follow the resume recommendation rather than deleting the namespace or rerunning cleanup blindly.