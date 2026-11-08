# Create KubeVirt Test VMs

Return to the [project README](../../README.md) and review the [policy architecture](../../doco/ARCHITECTURE.md). This task includes VM creation/boot checks and JSON-configured unattended Ubuntu provisioning. The original creator only boots installers; it does not install operating systems. None of these checks prove network-policy enforcement.

## Choose the Right Step

All `bash scripts/...` and `work/virtctl...` commands run from the repository root on the **physical host**, not inside a guest SSH session. Use `exit` to leave a guest before running host helpers. The outer VM and cluster must be running.

| Situation | Action |
| --- | --- |
| New lab with no task 30 VM resources | Complete tasks 20/25, then [create and boot-check](#create-and-boot-check) once |
| Existing installed lab | Read the [checkpoint](../../doco/IMPLEMENTATION-STATUS.md); do not rerun the creator |
| Ubuntu VM resource exists but OS is not provisioned | Use [unattended Ubuntu setup](#unattended-ubuntu-setup) |
| Rocky 10 test-server OS is not installed | Follow [manual installation](#install-rocky-linux), then [disk boot](#switch-to-installed-disk) and [admin bootstrap](#automate-rocky-administration) |
| Linux OS already installed | Use Ubuntu `--verify`/`--ssh` or [Rocky terminal access](#open-a-rocky-terminal); do not reinstall |
| Windows OS is not installed | Follow [Windows installation](#install-windows-server); this stage is manual |

Rocky 10 here is the policy-test server, not the separate [Rocky 9 graphical desktop](../32-rocky-desktop/README.md). Cloud-init administration is unattended; that does not make the Rocky 10 or Windows ISO installers unattended.

## Unattended Ubuntu Setup

For the Ubuntu client, use this path instead of the interactive ISO installer. Edit [ubuntu-client.json](ubuntu-client.json) in this directory. It sets the VM/hostname, admin username, time zone, memory, CPU cores, disk PVC/size/storage class, cloud-image URL and SHA-256, SSH-key paths, and timeout. Private keys and downloaded images remain under Git-ignored `work/`, not in the JSON file.

Prerequisites: task 20 is healthy and the managed `netpol-test` namespace and `netpol-client` VM resource already exist from the first boot-check run. With Rocky and Windows stopped, run:

```sh
bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --plan
bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --apply
```

Use `--config path/to/config.json` for another reviewed config. The script validates it and only targets the existing project-managed `netpol-client` VM. Apply downloads the official preinstalled Ubuntu 24.04 cloud image, verifies its configured SHA-256, uploads it into a new `netpol-client-cloud-disk` PVC, and attaches cloud-init with disk-first boot. The original `netpol-client-disk` and installer PVC are preserved; no existing disk is formatted or deleted. If the Ubuntu installer VM is running, apply gracefully stops it first. Do not use this conversion to continue a partially completed manual installation: that original disk remains preserved but is no longer the active boot disk. Rocky/Windows resources are not modified.

Cloud-init creates the configured administrator (default `labadmin`) with key-only SSH and unrestricted passwordless sudo for this disposable lab. It disables password/root SSH, sets hostname/time zone, and installs SSH and the QEMU guest agent. There is no shared/default password and no manual guest login. Protect the private key: possession grants administrative access. This sudo policy is not intended for production.

Apply waits for SSH and cloud-init completion, then checks OS release, root mount, networking, DNS, outbound HTTPS, sudo, SSH/guest-agent services, and reports effective SSH policy. It succeeds only when it prints `PASS Ubuntu unattended setup and key-based administration` and exits zero. The complete workflow passed on 2026-10-20 with Ubuntu 24.04.5 LTS; no viewer or password prompt was required.

For later checks and an interactive VS Code terminal shell:

```sh
bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --verify
bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --ssh
```

Use `exit` to leave SSH without stopping Ubuntu. Reapplying recognizes a completed cloud-image setup and reuses its disk; it does not reinstall the OS or reconcile changed cloud-init/user settings. Keep the config and keypair for that instance. A retry may resume an owned, checksum-matching incomplete upload only while the cloud disk is not attached to the VM. It refuses an unrecognized PVC or an attempt to upload over the active OS disk. If the rolling upstream image changes, checksum verification fails safely; review matching upstream metadata before updating the pin, rather than bypassing verification.

If outer-guest SSH fails because of the known OVN route issue, use the task 20 network diagnostic/guarded repair before retrying. Do not rerun `create-test-vms.sh` on installed guests: it restores the manual installer templates. Rocky's existing installation uses the separate post-install automation below; unattended Rocky installation and Windows unattended setup are not implemented by this Ubuntu script.

## Create and Boot-Check

**First build only.** This creates all three manual installer templates. Do not run it after any guest OS is installed or after cloud-image provisioning; it can restore ISO-first boot and original disk references.

From the repository root, preview the plan and then run the non-interactive creator:

```sh
bash scripts/30-create-kubevirt-vms/create-test-vms.sh --dry-run
bash scripts/30-create-kubevirt-vms/create-test-vms.sh
```

The script requires task 20 infrastructure to be healthy and task 25 media to be present. Its cluster preflight uses `check-cluster-status.sh --infrastructure-only`, so failed workload launcher pods do not prevent their own recovery; platform pods and all pinned configuration checks must still pass. It uploads installer media to CDI PVCs, creates plain PVCs for blank guest disks, then creates, starts, and stops each VM in this order: Rocky Linux server, Ubuntu client, Windows Server Evaluation. The PVCs use `local-path` with `WaitForFirstConsumer`; the VM mounts the PVC directly so its launcher pod can bind the disk without waiting for a CDI DataVolume to become `Succeeded`. The script verifies each VMI reaches `Running` and each disk PVC reaches `Bound`. It makes no terminal prompts. It can resume in the project-owned namespace using only expected resource names, checks existing PVC class/mode/access/capacity, skips completed ISO uploads, and refuses unexpected resources. During recovery it stops unfinished `Pending`/`Scheduling` VMIs and normally deletes a terminal `Failed` VMI only after verifying its controlling VM UID. Running guests are never interrupted; VM definitions, PVCs, and DataVolumes are preserved. It does not force deletion or remove finalizers.

The boot check confirms that KubeVirt launched the VM, not that an OS is installed. Afterward, Ubuntu uses the unattended cloud-image path above. Rocky 10 and Windows still use manual ISO installation; Windows evaluation terms and VirtIO driver selection remain manual.

The script requests 10 GiB disks for Ubuntu and Rocky and a 40 GiB disk for Windows. These are persistent local-path volumes. Before making changes, it requires free space for the rounded installer-media sizes, all requested disk capacities, and a 10 GiB reserve. The outer lab guest was created with a 100 GiB disk and has since been expanded to 130 GiB; disk images may grow sparsely, but the check does not assume that. If the guard fails, expand the outer disk with [`resize-lab-vm-disk.sh`](../10-create-lab-vm/README.md#resize-the-existing-vm-disk) and rerun. Avoid running the server VMs concurrently.

After creation, the script prints fully qualified `virtctl start` and `virtctl vnc` commands for each VM, including the exported kubeconfig path. Run the start command, then the VNC command, for one VM at a time to install its guest OS. Keep Windows powered off during Linux guest work. The creator leaves installer media attached and does not finalize or detach it after installation.

`virtctl start` schedules startup and returns before the VMI is necessarily Running. Wait for startup before opening VNC. If the viewer reports `VMI is not running`, check the progress report and retry only the VNC command after the VMI is Running; do not repeatedly start or recreate it.

## Install Rocky Linux

1. Keep Ubuntu and Windows stopped. From the repository root, open Rocky's installer:

	```sh
	export KUBECONFIG="$PWD/work/kubeconfig-lab-k8s-01.yaml"
	work/virtctl-v1.9.1 start netpol-server-rocky -n netpol-test
	work/virtctl-v1.9.1 vnc netpol-server-rocky -n netpol-test
	```

2. Select the Rocky Linux installation entry. Choose your language, keyboard, time zone, and Minimal Install if software selection is offered.
3. In Installation Destination, select only the existing approximately 10 GiB VirtIO disk (`vda`). Use automatic partitioning for this disposable lab disk. Do not target the installer CD-ROM or any host disk.
4. Enable the Ethernet connection in Network and Host Name and use DHCP. Set the hostname to `netpol-server-rocky`. Network installation sources need outbound access; do not continue with unresolved repository errors.
5. Create an administrator account and set its password directly in the installer. Keep credentials out of repository files and chat. Leave SELinux enabled.
6. Begin installation and wait for the completion/reboot prompt. Do not reboot straight back into the ISO. Use the stop and boot-switch sequence below, then reopen VNC.

## Switch to Installed Disk

After the installer reports completion, request a graceful KubeVirt stop from a host terminal. Do not stop a guest while installation is still writing files:

```sh
export KUBECONFIG="$PWD/work/kubeconfig-lab-k8s-01.yaml"
work/virtctl-v1.9.1 stop netpol-server-rocky -n netpol-test
```

Wait for the VMI to disappear. Preview and apply the guarded boot-order change:

```sh
bash scripts/30-create-kubevirt-vms/boot-installed-disk.sh netpol-server-rocky --dry-run
bash scripts/30-create-kubevirt-vms/boot-installed-disk.sh netpol-server-rocky
work/virtctl-v1.9.1 start netpol-server-rocky -n netpol-test
work/virtctl-v1.9.1 vnc netpol-server-rocky -n netpol-test
```

The helper discovers the outer guest address, checks project ownership and expected disk configuration, and refuses any existing VMI. It patches only boot priorities: `osdisk=1`, `installer=2`. It does not eject or delete the ISO, PVCs, or guest disk, and it neither stops nor starts guests. An in-guest reboot alone does not create a new VMI and cannot reliably pick up the changed VM template; use the full stop/start sequence. If stop does not complete, inspect the guest instead of forcing it off or deleting its VMI.

Confirm VNC shows the installed Rocky login screen rather than the installer, then log in and check `cat /etc/os-release`, `findmnt /`, `ip -br address`, and `ip route`. VMI `Running` alone does not verify the installed OS. Stop Rocky before installing Ubuntu. The same helper accepts `netpol-client` and `netpol-server-windows` after their installations finish.

Do not rerun `create-test-vms.sh` during or after OS installation: it reapplies ISO-first boot priority. The boot-switch helper does not prove installation success or mark guest configuration complete.

## Automate Rocky Administration

The existing Rocky installation can be preserved. These scripts create `labadmin`, install its dedicated Ed25519 public key, enable SSH and the QEMU guest agent, and check the OS, storage, network, DNS, outbound HTTPS, and passwordless sudo. `labadmin` has unrestricted passwordless sudo for this disposable lab; possession of its private key grants administrative access. Do not use this policy unchanged in production.

The host helper stores its private key and per-VM known-hosts file only in ignored `work/`. It never uses a shared/default password. Keep those files private and back up the key securely. It uses `virtctl ssh` through the Kubernetes API, not the guest's internal `10.0.2.2` address, a public service, or a host listener. Rocky's masquerade interface must include TCP 22; new Rocky templates now include it alongside test ports 8080 and 8081. NetworkPolicies must explicitly permit management traffic when introduced.

Prepare the key and perform the one-time bootstrap using an existing administrator, for example the `paul` account created during installation:

```sh
bash scripts/30-create-kubevirt-vms/setup-rocky-access.sh --prepare
bash scripts/30-create-kubevirt-vms/setup-rocky-access.sh --bootstrap-user paul
```

Enter any SSH or sudo password directly in the terminal, never in chat or command arguments. The helper sends the version-controlled [guest setup script](configure-rocky-guest.sh) over the authenticated connection and runs it with sudo. It does not reinstall Rocky, format disks, or reset existing users. Without a preinstalled trusted key or guest agent, this existing VM cannot securely bootstrap its own credentials without that one-time authentication.

After the bootstrap, the helper verifies a separate `labadmin` key-authenticated connection with `BatchMode=yes`. Only after that succeeds does it disable password authentication, keyboard-interactive authentication, and root SSH login, reload SSH, and verify key access again. Existing console credentials are not changed. If setup stops early, do not assume hardening completed; inspect the error and rerun verification before retrying.

Subsequent checks require no manual login:

```sh
bash scripts/30-create-kubevirt-vms/setup-rocky-access.sh --verify
```

This workflow was completed against the existing Rocky 10.2 VM on 2026-10-20. A separate noninteractive verification passed after hardening, and Kubernetes reported the guest agent connected. Rocky was subsequently stopped for Ubuntu's unattended provisioning. See the checkpoint for current runtime state.

If bootstrap reached verification but stopped before hardening, retry explicitly after fixing the reported issue:

```sh
bash scripts/30-create-kubevirt-vms/setup-rocky-access.sh --harden
```

The bootstrap and hardening steps can be rerun with the same key. After hardening, use `--bootstrap-user labadmin` to repeat provisioning through its installed key and passwordless sudo; the original administrator's password can no longer authenticate over SSH. Existing authorized keys are preserved; unexpected SSH policy files are not overwritten. Do not regenerate the key or delete known-hosts entries to bypass an authentication or host-key mismatch.

These Rocky 10 scripts automate post-installation administration, not installer screens. Fresh unattended Rocky 10 installation needs a separate workflow; do not rebuild the installed server. Ubuntu automation is in its own helper above. The Rocky 9 desktop has a separate unattended cloud-image workflow; Windows unattended setup is not implemented.

## Open a Rocky Terminal

After completing SSH bootstrap, use the VS Code integrated terminal instead of Virtual Machine Viewer for normal administration. Run from the repository root on the physical host:

```sh
export KUBECONFIG="$PWD/work/kubeconfig-lab-k8s-01.yaml"
work/virtctl-v1.9.1 ssh labadmin@vmi/netpol-server-rocky -n netpol-test \
	--identity-file="$PWD/work/netpol-server-rocky_ed25519" \
	--known-hosts="$PWD/work/netpol-server-rocky_known_hosts" \
	--local-ssh-opts=-tt \
	--local-ssh-opts='-o BatchMode=yes' \
	--local-ssh-opts='-o IdentitiesOnly=yes' \
	--local-ssh-opts='-o StrictHostKeyChecking=yes'
```

This opens an interactive shell as `labadmin` without a password prompt, using the existing verified host key. It stays inside the terminal, with the terminal's normal copy/paste and font settings. Use `sudo` for administration and `exit` to return to the host; exiting SSH does not stop the VM. Do not delete the known-hosts file or disable host-key checking if a mismatch is reported.

The outer VM, Kubernetes API, and Rocky VMI must be running. If Rocky is stopped, start it first using the same exported kubeconfig:

```sh
work/virtctl-v1.9.1 start netpol-server-rocky -n netpol-test
```

Wait for Rocky to finish booting before connecting. For noninteractive checks, continue using `setup-rocky-access.sh --verify`. The viewer is only needed for initial manual OS installation or console recovery; normal Rocky administration can now use SSH. Ubuntu has the config-driven `setup-ubuntu-client.sh --ssh` path above; Windows remote access is not yet configured.

## Install Windows Server

### Administrator Credentials

The unattended setup configuration is [windows-server.json](windows-server.json). It records username `Administrator` and the password-file path, never the password itself. A configuration file or prepared password alone does not mean the OS/account is installed; wait for successful installation verification.

The setup helper generates the password into Git-ignored `work/windows-administrator-password` with owner-only mode `0600` before creating installation media. Open that file privately in VS Code after the helper reports it was created; do not paste it into chat or commit it. For console sign-in, use `Administrator` or `.\Administrator` with that password. Preparation and retries reuse the existing file. Do not delete or regenerate it after installation to attempt a password reset: changing the local file does not change Windows credentials. Record any later guest-side password change in your password manager.

### Unattended Installation

**Paused / repair validated (2026-10-21): do not rerun installation into the existing failed disk yet.** Windows Setup rejected the previous generated `RunSynchronousCommand/Path` because it was 1,458 characters, exceeding Microsoft's 259-character limit. The generator now uses a short file-based launcher and fails if the rendered path exceeds 259 characters; the regenerated XML and Secret pass validation. The failed system disk is preserved, and a checksummed recovery copy exists. Next, retry only into a new or explicitly approved clean disk; do not attempt in-place resume. See the [pause handoff](../../doco/IMPLEMENTATION-STATUS.md#paused-handoff---2026-10-21).

The current workflow targets the approved Standard Evaluation Desktop Experience image (index 2, confirmed as `ServerStandardEval` in the staged ISO). Accept Microsoft's terms only after reviewing them; `acceptEvaluationTerms` is an explicit prerequisite in JSON, not a license bypass.

From the physical host's repository root:

```sh
bash scripts/30-create-kubevirt-vms/setup-windows-server.sh --plan
bash scripts/30-create-kubevirt-vms/setup-windows-server.sh --prepare
bash scripts/30-create-kubevirt-vms/setup-windows-server.sh --apply
```

`--prepare` creates the private credential files, SSH key, XML answer file, and Secret manifest under ignored `work/`; it makes no VM changes. Generated answer files and the Kubernetes Secret contain the administrator password and must be treated as credentials, even though JSON configuration and template files do not contain it. Do not display/diff the generated XML or Secret in chat.

`--apply` checks ownership and media, gracefully stops Ubuntu and the Rocky desktop, and requires other nested guests to be stopped. It creates a **new 40 GiB SATA disk** (`netpol-server-windows-unattended-disk`) and preserves the original Windows disk and all Linux disks. The answer file partitions only that new disk. SATA avoids requiring a storage driver inside Windows PE; the guest bootstrap installs Server 2025 VirtIO network/serial drivers and the QEMU agent from the pinned driver CD, then enables Windows OpenSSH with the dedicated administrator key. OpenSSH installation requires working Windows package/update access.

The helper waits for verified key-authenticated administration, then performs a full stop/start to switch to disk-first boot and detach/delete the password-bearing answer media Secret. Private local credential/answer files remain protected under `work/`; back up or dispose of them deliberately. Reapply does not format a recognized installed disk. If an unrecognized installation disk already exists, the script refuses rather than overwriting it. There is no automatic rollback or guarantee that every Windows update/driver step will succeed: inspect setup errors before retrying.

For verification, terminal administration, or the console after setup:

```sh
bash scripts/30-create-kubevirt-vms/setup-windows-server.sh --verify
bash scripts/30-create-kubevirt-vms/setup-windows-server.sh --ssh
bash scripts/30-create-kubevirt-vms/setup-windows-server.sh --vnc
```

Console login uses the private password; scripted SSH uses the dedicated key, not the password. These helpers do not configure Windows RDP or prove policy enforcement. Do not run the original VM creator or the old VirtIO-only boot-switch helper on the unattended SATA layout.

### Manual Installation

This is the legacy manual alternative for the original VirtIO-disk layout. Do not mix it with an unattended installation already using the new SATA disk. Use only the project-owned `netpol-server-windows` VM already created by the boot-check script.

1. Stop Ubuntu, Rocky, and any desktop workloads as needed for capacity. Confirm Windows media and the verified VirtIO driver disk are attached; do not rerun the creator on installed guests.
2. From the physical host, export `KUBECONFIG="$PWD/work/kubeconfig-lab-k8s-01.yaml"`, run `work/virtctl-v1.9.1 start netpol-server-windows -n netpol-test`, wait for Running, then run `work/virtctl-v1.9.1 vnc netpol-server-windows -n netpol-test`.
3. Follow Microsoft's evaluation terms and select the intended edition. Choose Desktop Experience if a graphical Windows desktop is required.
4. Select only the existing 40 GiB guest OS disk. If it is not visible, use Load Driver and the attached driver CD-ROM to select the compatible amd64 VirtIO block-storage driver (`viostor` for the current virtio disk bus). Do not format installer media or unrelated disks.
5. Complete installation and enter account credentials directly in the console, not in chat or Git. When installation is complete, perform a full stop, wait for the VMI to disappear, and run `bash scripts/30-create-kubevirt-vms/boot-installed-disk.sh netpol-server-windows` before starting again.
6. Install compatible VirtIO network/guest drivers, verify the installed OS, and configure the test services before policy tests. A successful launcher boot does not certify Windows driver compatibility or policy enforcement.

Keep the evaluation licensing and driver compatibility limitations in the checkpoint. Windows remote administration and unattended setup are still pending; the Linux SSH helpers do not configure Windows.

## Troubleshooting

- If a blank disk remains `WaitForFirstConsumer`, ensure the VM consumes a plain PVC; CDI blank DataVolumes can remain in `PVCBound` in this single-node `local-path` setup. The current creator uses direct PVC-backed guest disks.
- If a VMI stays `Pending`, inspect `kubectl describe vmi` and the namespace events before retrying. Do not assume that creating the `VirtualMachine` object means its launcher pod or disk is ready.
- The Windows template pins the official `quay.io/kubevirt/virtio-container-disk` amd64 build tagged `20261020_bb5dc762db-amd64` by digest: `sha256:06a32bc8a4d84d2d8d86ef06ba92dad00d78d1b34cec2ee48e17a2fbe438a094`. Its registry manifest was verified as OCI schema 2, and the Windows VMI reached `Running` with this image on 2026-10-20. Do not revert to the untagged `latest` image, which previously failed with a deprecated Docker schema-1 manifest. When updating the pin, verify manifest format, architecture, and a real Windows VMI boot check; driver selection and Windows installation remain manual.
- On failure, use `bash scripts/check-lab-progress.sh` to inventory existing resources and get a resume recommendation. The creator preserves existing disks and does not clean up partial state automatically.

Continue with [task 35: verify Kubernetes isolation](../35-verify-kubernetes-isolation/README.md) after guest OS installation and configuration.