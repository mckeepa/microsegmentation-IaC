# Create KubeVirt Test VMs

Return to the [project README](../../README.md) and review the [policy architecture](../../doco/ARCHITECTURE.md). This task creates and boot-checks KubeVirt VM resources; it does not install guest operating systems or prove network-policy enforcement.

## Create and Boot-Check

From the repository root, preview the plan and then run the non-interactive creator:

```sh
bash scripts/30-create-kubevirt-vms/create-test-vms.sh --dry-run
bash scripts/30-create-kubevirt-vms/create-test-vms.sh
```

The script requires task 20 to be healthy and task 25 media to be present. It uploads installer media to CDI PVCs, creates plain PVCs for blank guest disks, then creates, starts, and stops each VM in this order: Rocky Linux server, Ubuntu client, Windows Server Evaluation. The PVCs use `local-path` with `WaitForFirstConsumer`; the VM mounts the PVC directly so its launcher pod can bind the disk without waiting for a CDI DataVolume to become `Succeeded`. The script verifies each VMI reaches `Running` and each disk PVC reaches `Bound`. It makes no terminal prompts. It can resume in the project-owned namespace using only expected resource names, checks existing PVC class/mode/access/capacity, skips completed ISO uploads, and refuses unexpected resources. It stops only unfinished `Pending` VMIs during recovery; running guests are never interrupted, and it does not delete resources automatically.

The boot check confirms that KubeVirt launched the VM. It does not confirm that an operating system was installed or booted successfully. OS installation remains interactive in a VM console. Windows installation additionally requires Microsoft Evaluation Center terms to be accepted and VirtIO drivers to be selected manually; this project does not automate those steps.

The script requests 10 GiB disks for Ubuntu and Rocky and a 40 GiB disk for Windows. These are persistent local-path volumes. Before making changes, it requires free space for the rounded installer-media sizes, all requested disk capacities, and a 10 GiB reserve. The outer lab guest has a 100 GiB disk; disk images may grow sparsely, but the check does not assume that, so increase guest storage if the guard fails. Avoid running the server VMs concurrently.

After creation, the script prints fully qualified `virtctl start` and `virtctl vnc` commands for each VM, including the exported kubeconfig path. Run the start command, then the VNC command, for one VM at a time to install its guest OS. Keep Windows powered off during Linux guest work. The creator leaves installer media attached and does not finalize or detach it after installation.

## Troubleshooting

- If a blank disk remains `WaitForFirstConsumer`, ensure the VM consumes a plain PVC; CDI blank DataVolumes can remain in `PVCBound` in this single-node `local-path` setup. The current creator uses direct PVC-backed guest disks.
- If a VMI stays `Pending`, inspect `kubectl describe vmi` and the namespace events before retrying. Do not assume that creating the `VirtualMachine` object means its launcher pod or disk is ready.
- The Windows template currently references `quay.io/kubevirt/virtio-container-disk:latest`. On this lab's containerd 2.3, the pull failed because the image uses a deprecated Docker schema-1 manifest. Replace it with a verified OCI/schema-2-compatible VirtIO driver image before retrying the Windows boot check.
- On failure, use `bash scripts/check-lab-progress.sh` to inventory existing resources and get a resume recommendation. The creator preserves existing disks and does not clean up partial state automatically.

Continue with [task 35: verify Kubernetes isolation](../35-verify-kubernetes-isolation/README.md) after guest OS installation and configuration.