# Implementation Status

## Paused Handoff - 2026-10-21

Work is paused at the user's request. No repair, reinstall, disk replacement, or VM restart was performed after diagnosis. The host-side `setup-windows-server.sh --apply` waiter was deliberately terminated with SIGTERM (exit `143`) so it cannot continue automatically while the work is paused. Existing dashboard/Switchboard services were left alone.

### State Left Behind

| Component | Confirmed pause state |
| --- | --- |
| Outer `lab-k8s-01` | Running; 24 GiB live RAM, **30 GiB next-boot RAM**; do not restart just to activate the pending memory setting |
| `netpol-server-windows` | VMI Running, but Windows Setup is blocked; no guest-agent connection, OS verification, or SSH access |
| `netpol-client` | Stopped; installed Ubuntu disk preserved |
| `netpol-server-rocky` | Stopped; installed Rocky 10 disk preserved |
| Optional `rocky-desktop` | Stopped; installed Rocky 9 desktop disk preserved; its earlier RDP tunnel closed when it was stopped |

Windows uses `netpol-test/netpol-server-windows-unattended-disk`, PV `pvc-7f4116df-16a9-4f1b-8518-c48108dd3719`. This is the new 40 GiB SATA system disk. The original `netpol-server-windows-disk` is preserved and is not the active system disk. The VM still has installer-first boot (`installer=1`, `osdisk=2`), the pinned VirtIO driver CD, and sysprep Secret `windows-unattended-seed` attached. Post-install disk-first switching/answer-media removal did **not** complete.

### Confirmed Failure

The console says: "The computer restarted unexpectedly or encountered an unexpected error. Windows installation cannot proceed."

Read-only diagnostics used the launcher's `virsh send-key` to open Shift+F10. The administrator command prompt was left open over the setup error; the error dialog was not accepted. A filtered query of `C:\Windows\Panther\setuperr.log` reported an invalid unattended value in `Microsoft-Windows-Deployment/RunSynchronous`, error `0x80220005`. The bootstrap log directory was absent, consistent with rejection before the provisioning script ran.

The source generator embeds a **1,458-character** PowerShell encoded command in `RunSynchronousCommand/Path`. Microsoft's documented maximum is **259 characters** ([Path reference](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-runsynchronous-runsynchronouscommand-path)). This automation defect is confirmed; it is not currently evidence of insufficient RAM or a failed VirtIO driver install. The source has **not yet been repaired**.

Relevant tracked files:

- [Answer-file generator](../scripts/30-create-kubevirt-vms/prepare-windows-unattended.mjs): `bootstrap` and `encoded` construct the oversized command.
- [XML template](../scripts/30-create-kubevirt-vms/windows-unattend.xml): `specialize` / `Microsoft-Windows-Deployment` / `RunSynchronousCommand/Path`.
- [Guest provisioning script](../scripts/30-create-kubevirt-vms/configure-windows.ps1): drivers, QEMU agent, and OpenSSH steps are not verified on this installation.
- [Host orchestrator](../scripts/30-create-kubevirt-vms/setup-windows-server.sh) and [approved JSON config](../scripts/30-create-kubevirt-vms/windows-server.json).

Local diagnostic screenshots are in ignored `work/windows-status.png`, `work/windows-diagnostic-console.png`, and `work/windows-setup-errors.png`. They are diagnostic evidence, not completed-OS verification. Do not publish generated answer media or credentials.

### Credentials and Safety

- Windows username: `Administrator` (console: `.\Administrator`). Its generated password is saved privately in `work/windows-administrator-password`, mode `0600`; account usability is not yet verified. Preserve this file and the matching Windows SSH keypair. Regenerating a local file does not reset the installed account.
- `work/windows-unattended/autounattend.xml`, `work/windows-unattended/secret.json`, and the attached Kubernetes Secret contain password-bearing answer data. Keep them private; do not print/diff them into chat or commit them.
- Cockpit's previously exposed password was rotated successfully. The replacement is in private `work/cockpit-monitor-password`; existing authenticated sessions are not revoked by a password change.
- Do not run task 90 cleanup, the original VM creator, the VirtIO-only boot-switch helper, a disk-formatting operation, or a blind reinstall. Do not edit setup registry state to bypass the error before assessing recovery.

The [Resume Order](#resume-order) below is the starting point for the next session. Current runtime state may differ after a host shutdown; recheck it without starting a fresh installation.

Last progress inventory: 2026-10-20 22:24 +11:00 (`scripts/check-lab-progress.sh`). Last full pinned cluster configuration check: 2026-10-20 21:27 +11:00.

## Read This First

This file records dated evidence, not guaranteed live state. Run commands from the physical host's repository root, not inside `netpol-client` or another SSH session.

1. Run `bash scripts/check-lab-progress.sh` and read its warnings and `NEXT:` line; exit zero only means the inventory completed.
2. Use [Where We Are](#where-we-are) and [Resume Order](#resume-order) to choose the next task. Do not recreate installed guests.
3. For access rather than installation, use [guest SSH](../scripts/30-create-kubevirt-vms/README.md#choose-the-right-step), [desktop RDP](../scripts/32-rocky-desktop/README.md#rdp-access), or [dashboard access](../scripts/45-monitoring-dashboard/README.md#open-the-dashboards).

## Installation History

Subsequent guest installation update, 2026-10-20: Rocky installation completed per the user; its full stop/start and disk-first VMI configuration were verified. A VNC capture confirmed Rocky Linux 10.2 (Red Quartz) at the `netpol-server-rocky login:` prompt. Login and networking were subsequently confirmed by the user and scripted checks below.

Subsequent access automation update, 2026-10-20: the existing administrator authenticated directly in the terminal and the bootstrap completed. `labadmin` now has its dedicated SSH key and passwordless lab sudo; the private key stays in ignored `work/`. Independent noninteractive checks passed for Rocky 10.2, XFS/LVM root, DHCP address `10.0.2.2/24`, default route via `10.0.2.1`, DNS, outbound HTTPS, sudo, SSH, and the guest agent. Effective SSH policy confirms public-key authentication enabled and password, keyboard-interactive, and root SSH login disabled. Kubernetes reports `AgentConnected=True` and Rocky OS details. Rocky's masquerade interface forwards TCP 22 alongside 8080/8081; the guarded template patch and graceful restart preserved disk-first boot and the installed disk. A fresh unattended installation/Kickstart workflow is not implemented by these post-install scripts.

This is the durable project checkpoint. Run `bash scripts/check-lab-progress.sh` for a fresh inventory before resuming; live state may have changed since this note was written. If the managed outer VM is powered off, the checker prompts for permission to start it and waits up to five minutes for networking and SSH. Without approval it stops and reports verification as incomplete. Update this file whenever a task completes or a new blocker is found.

## Where We Are

Windows Standard Evaluation with Desktop Experience was approved, and the ISO's index 2 was verified as `ServerStandardEval`. Setup later failed in the `specialize` pass because the generated synchronous command exceeds Microsoft's length limit. The earlier 75% progress observation is superseded by the confirmed blocked state in the pause handoff above. The new SATA disk, original Windows disk, credentials, and attached answer media are preserved; source repair and safe in-place recovery remain pending.

Rocky and Ubuntu are installed and currently stopped. Ubuntu's desired setup is recorded in [ubuntu-client.json](../scripts/30-create-kubevirt-vms/ubuntu-client.json); cloud-init, key-based administration, sudo, networking, and repeat-apply checks previously passed. These are prior installation results, not live checks of stopped guests. The historical progress inventory above passed host/cluster checks, but available physical-host memory later fell below the 32 GiB pre-provisioning threshold. The new memory helper changes next-boot VM allocation, not physical host capacity.

| Task | State |
| --- | --- |
| 00 Host preflight | Done |
| 10 Outer VM `lab-k8s-01` | Running; disk expanded 100 → 130 GiB |
| 20 K3s / OVN / KubeVirt / CDI | Healthy; all pinned configuration checks passed |
| 25 Guest media | Done; ISOs staged and uploaded |
| 30 KubeVirt test VMs | Windows VM running at a setup error; Ubuntu, Rocky, and optional desktop stopped |
| 30 Guest OS installs | Rocky/Ubuntu installed; Windows blocked by confirmed unattended-command length defect; work paused |
| 35 Isolation tests | Not started |
| 40 Azure/NSX static checks | Not started |
| 45 Monitoring dashboards | Cockpit 314 and Headlamp v0.46.0 installed; loopback HTTPS/HTTP checks and permission toggles passed; read-only restored; Cockpit password generated and saved privately in ignored work/ |

**Next session: repair and validate the short Windows setup launcher, then assess recovery of the preserved installation.** Do not treat a Running VMI as successful OS setup. See [Resume Order](#resume-order); isolation tests remain blocked until guest configuration is complete.

## Monitoring Access

Lab Switchboard was deployed as a non-root container in namespace `lab-switchboard` on 2026-10-21. The [project guide](../lab-switchboard/README.md) documents image build/import, deployment, laptop access, guest commands, and security limits. Run `bash lab-switchboard/scripts/access.sh` on the physical host to expose <http://localhost:18088>; the random portal password is stored in the ignored project-local `.local/admin-password` file with mode `0600`. Unit/API tests, the npm dependency audit, deployed readiness/RBAC checks, authenticated live inventory of all four VMs, and desktop/mobile demo-browser checks passed. Both guarded lifecycle paths also passed against real KubeVirt using explicit dry-run requests; a response-negotiation regression test covers its empty HTTP 202 replies. Validation did not change guest VM state. Headlamp/Cockpit links still require the task 45 tunnel. This portal does not change Windows installation or isolation-test status.

Task 45 was installed and verified on 2026-10-20. See the [monitoring inventory](MONITORING.md) and [dashboard runbook](../scripts/45-monitoring-dashboard/README.md). Headlamp is a ClusterIP deployment in `lab-dashboard`; Cockpit listens only on the outer VM's `127.0.0.1:9090`. The helper exposes host-loopback URLs <http://localhost:18080> and <https://localhost:19090> while its SSH tunnel runs. A separate laptop requires the documented second SSH tunnel.

Live admin/read-only authorization tests passed and access was restored to read-only. A short-lived Headlamp login token was generated into ignored `work/headlamp-token` with mode `0600`; regenerate it after expiration. Cockpit's dedicated `cockpit-monitor` password was subsequently reset using task 45 `--generate-cockpit-password` and saved to ignored `work/cockpit-monitor-password` with mode `0600`; the account reports an active password. Headlamp rendered in the integrated browser; Cockpit returned HTTPS 200 with its self-signed certificate, which the integrated browser rejected as untrusted. Authenticated browser login and access from a separate laptop remain to be verified by the user. Dashboard visibility does not prove network-policy enforcement.

## Completed

- Host preflight passed: 16 logical CPUs, KVM access and nested virtualization enabled. Disk and available RAM are dated observations in the inventory above, not fixed capacity guarantees; rerun preflight before adding workloads.
- The managed outer VM `lab-k8s-01` is running. Its QCOW2 virtual disk was expanded online from 100 GiB to 130 GiB; Ubuntu partition, LVM, and root filesystem growth completed successfully.
- The task 20 K3s/OVN/KubeVirt/CDI health check passed. When the libvirt DHCP lease expired, the QEMU guest agent still reported the OVN bridge address; the SSH recovery restored the default route. The checker and diagnostics now use a non-link-local guest-agent address when no DHCP lease is available.
- Task 25 media is staged and has been uploaded to Kubernetes: Rocky Linux 10, Ubuntu Server 24.04.5, and Windows Server 2025 Evaluation.

## Current Task 30 State

- Namespace `netpol-test` exists and is labeled `microsegmentation-iac` as its manager.
- Rocky server `netpol-server-rocky` was installed manually. At the installer reboot prompt, it was gracefully stopped; the guarded `boot-installed-disk.sh` helper set `osdisk=1` and `installer=2`, and a fresh VMI reached Running/Ready with those priorities. The console showed installed-system startup and login. Installer media and persistent volumes remain attached and preserved. Subsequent key-based SSH checks confirmed OS release, root mount, network/DNS/HTTPS, passwordless sudo, and SSH/guest-agent services; SSH password/root login hardening is verified. Test-service configuration remains pending.
- Ubuntu client `netpol-client` is installed on the project-owned `netpol-client-cloud-disk` (10 GiB) and currently stopped. The original disk, DataVolume, and ISO PVC are preserved. Cloud-init, key-based administration, OS/network/service checks, and the Ubuntu 24.04.5 guest-agent report passed before stopping it for Windows setup.
- Windows server `netpol-server-windows` is running on the new SATA disk but blocked in setup; no OS/SSH/guest-agent success is verified. Its original VirtIO disk remains preserved. See the pause handoff for the specific defect and current attached media.
- Replaced the schema-1 `latest` VirtIO driver image with the official amd64 build `20261020_bb5dc762db-amd64`, pinned as `quay.io/kubevirt/virtio-container-disk@sha256:06a32bc8a4d84d2d8d86ef06ba92dad00d78d1b34cec2ee48e17a2fbe438a094`. The registry manifest is OCI schema 2, and the real Windows boot check passed.
- The stale failed Windows VMI was removed through normal deletion after verifying its controlling VM UID. The VM definition, all disks, installer PVCs, and DataVolumes were preserved. Task 30 now uses infrastructure-only preflight so it can recover failed workload launchers without weakening the default full cluster check.
- All three original guest disk DataVolumes report `Succeeded`, and all seven disk/installer/cloud PVCs are bound. The Ubuntu cloud-image upload and boot were validated end to end. The original disks and media remain preserved.
- Outer-guest `/` had about 84 GiB free at the latest check, near task 30's 84 GiB guard. Recheck capacity before importing more images or starting Windows work.
- SSH is reachable at `192.168.122.162`, and a fresh guest DNS lookup of `quay.io` succeeded. Rediscover the address after future power cycles rather than assuming it is unchanged.

## Resume Order

1. Read the pause handoff above. Recheck outer VM/VMIs and capacity from the physical host. The progress checker is an inventory aid, not proof of Windows completion; do not blindly follow any old recommendation to recreate resources or reinstall.
2. Fix the source generator/template so `RunSynchronousCommand/Path` contains a short launch command (at most 259 characters) and invokes a separate bootstrap file on the attached seed media. Add a regression check on the **fully rendered** command length and validate XML without displaying password-bearing data.
3. Before touching the existing installation, assess recovery using the preserved disk, setup logs, and current Windows setup phase. Updating the Kubernetes Secret alone may not update Windows' cached answer file. Plan a safe backup/snapshot or read-only inspection before any in-place write. Do not use `WillWipeDisk=true` on the partially installed disk or assume rerunning `--apply` is recovery.
4. Resume only an evidence-supported repair that preserves the disk and credential files. If a destructive reinstall becomes necessary, obtain explicit user approval first. The initial request was to preserve this disk.
5. After Windows finishes, verify actual OS details, key-based SSH, drivers, QEMU guest agent, and services. Only then complete guarded disk-first boot and detach/delete the password-bearing answer media. The current `boot-installed-disk.sh` expects the original VirtIO layout and must not be used on this SATA disk.
6. Reconcile the task 30 README's stale manual-only Windows wording and the status/checker recommendations once the repaired unattended path is validated. Record tested versus untested behavior accurately. Linux guests may be started later as needed; they are not broken or awaiting reinstallation.
7. Continue to task 35 only after guest OS/service configuration is complete. The legacy `run-isolation-test.sh` is not a compatible follow-on to the current task 30 resources. The optional Switchboard/dashboard work is independent; preserve its existing changes.

## Optional Rocky Desktop

The separate JSON-configured [task 32 desktop](../scripts/32-rocky-desktop/README.md) was provisioned unattended on 2026-10-20 after capacity and package checks. Rocky 9 was selected with user approval because the proposed XFCE/xrdp packages were available in EPEL 9, not the checked EPEL 10 listing. This does not change the installed Rocky 10 test server.

- Namespace/VM: `rocky-desktop`; disk: `rocky-desktop-disk` (30 GiB); 4 vCPUs and 6 GiB RAM. Configuration: [rocky-desktop.json](../scripts/32-rocky-desktop/rocky-desktop.json).
- Rocky 9.8 cloud-init completed without errors. Independent checks passed for XFCE, Firefox, xrdp/xorgxrdp, LightDM, SSH, guest-agent service, and enforcing SELinux.
- VNC screenshot confirmed the graphical login screen. Firefox successfully rendered an HTTPS page as non-admin user `desktop`.
- xrdp listens only on the guest loopback address. SSH tunnel `127.0.0.1:13389` reached successful RDP security negotiation; no public RDP port or Kubernetes Service was created.
- Admin `labadmin` uses a dedicated ignored private key and lab passwordless sudo. The separate `desktop` user's password was set privately, and the user confirmed an interactive RDP session. Intentional logout returned FreeRDP code `12` (`ERRINFO_LOGOFF_BY_USER`); xrdp remained active. The server certificate fingerprint was matched through trusted SSH.
- Existing Rocky, Ubuntu, and Windows resources were not modified. This optional desktop is outside the three-guest isolation matrix; include its memory/disk use in later capacity planning.

## Recovery Notes

- During Ubuntu cloud-image setup, outer-guest SSH lost its address/default route due to the known OVN issue. The existing guarded runtime repair restored it; this is not a new persistent network fix. CDI also required an explicit `cdi.kubevirt.io/storage.bind.immediate.requested=true` annotation for an existing PVC upload. The new script sets this, safely retries only owned/inactive incomplete cloud disks, and tracks both local and remote upload forwarders for cleanup.
- For missing SSH after a lease expires, use `scripts/20-install-k3s-kubevirt/repair-guest-network.sh --diagnose`; the cluster checker also attempts the guarded runtime repair. It is not persistent across reboot.
- To expand the outer VM disk, use `bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh <total-size-gib>`. Do not run `qemu-img resize` against the active disk.
- Task 30 failures may leave PVCs, DataVolumes, VMs, or VMIs behind. The creator preserves persistent resources and only removes terminal failed VMIs after verifying ownership. Inspect the live state and follow the resume recommendation rather than deleting the namespace or rerunning cleanup blindly.
- After each completed guest installation, use `bash scripts/30-create-kubevirt-vms/boot-installed-disk.sh <vm-name>` with the guest fully stopped. The helper refuses existing VMIs and unexpected ownership/configuration, preserves media and PVCs, and leaves the guest stopped for an explicit start. Use `--dry-run` to preview without changing resources.