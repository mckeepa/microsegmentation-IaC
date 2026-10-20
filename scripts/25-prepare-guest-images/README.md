# Prepare KubeVirt Guest Images

Return to the [project README](../../README.md) for the lab's scope and the [VM inventory](../../doco/LAB-SETUP.md) for guest roles and sizing. This task prepares the OS installation media for the Kubernetes isolation tests. It does not install or create VMIs; that depends on the selected KubeVirt storage class and CNI.

All ISO files and temporary download data are stored in the ignored repository-root `work/` directory.

## 1. Ubuntu Client

Ubuntu Server 24.04.5 is the initial client OS and is downloaded as the outer lab guest's bootstrap image too.

The ISO below is used by task 10 and the original task 30 boot-check path. The current unattended Ubuntu client uses a separate checksum-pinned cloud image downloaded by `setup-ubuntu-client.sh`; do not manually install that client from the ISO. The optional Rocky desktop also downloads its own cloud image in task 32.

1. From the project root, run:

   ```sh
   bash scripts/10-create-lab-vm/download-ubuntu-server.sh
   ```

2. Confirm `work/ubuntu-24.04.5-live-server-amd64.iso` exists. The downloader verifies Ubuntu's signed checksum list and the ISO's SHA-256 before reporting success.

## 2. Rocky Linux 10 Server

1. From the project root, run:

   ```sh
   bash scripts/25-prepare-guest-images/download-rocky-10.sh
   ```

2. The script fetches the current Rocky Linux 10 minimal x86_64 ISO and its signed checksum, verifies the detached signature against the pinned Rocky Linux 10 signing-key fingerprint, then verifies the ISO checksum.
3. Confirm `work/Rocky-10-latest-x86_64-minimal.iso` exists. This minimal ISO uses network repositories during installation, so the guest needs outbound access while installing.

## 3. Windows Server 2025 Evaluation

Microsoft's Evaluation Center uses an interactive, terms-controlled download. Download the x64 ISO yourself from the [official Windows Server 2025 Evaluation Center](https://www.microsoft.com/en-us/evalcenter/download-windows-server-2025), accept Microsoft's current evaluation terms, and save the ISO outside the repository.

Then stage it under the ignored `work/` directory:

```sh
bash scripts/25-prepare-guest-images/prepare-windows-server-2025.sh /path/to/Windows_Server_2025_Evaluation.iso
```

The helper checks that the input looks like ISO/UDF media and copies it to `work/windows-server-2025-evaluation.iso`. It does not bypass Microsoft's sign-in or agreement, grant a license, or independently authenticate the media. Keep the original download source and any Microsoft-published hash with your test record.

## 4. Confirm All Media

```sh
ls -lh work/*.iso
```

Task 10 uses the Ubuntu ISO for unattended outer-VM installation; do not create another manual copy in Virtual Machine Manager. Rocky and Windows ISOs are for nested KubeVirt guests. After the cluster is configured, follow [task 30](../30-create-kubevirt-vms/README.md), including its unattended Ubuntu path. Task 35 remains a validation plan, not a compatible automated follow-on runner.

For Windows, attach the matching KubeVirt `virtio-win` driver disk as a CD-ROM during installation and load the storage driver when prompted. Install the guest network driver before testing traffic. Run the Windows guest separately from the Rocky guest to stay within the planned resource budget, and treat Windows Server 2025 support as unverified until the pinned KubeVirt release boots it and the network-policy tests pass.
