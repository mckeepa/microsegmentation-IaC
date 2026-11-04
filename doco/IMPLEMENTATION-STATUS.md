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

### Confirmed Failure and Repair Evidence

The console says: "The computer restarted unexpectedly or encountered an unexpected error. Windows installation cannot proceed."

Read-only diagnostics used the launcher's `virsh send-key` to open Shift+F10. The administrator command prompt was left open over the setup error; the error dialog was not accepted. A filtered query of `C:\Windows\Panther\setuperr.log` reported an invalid unattended value in `Microsoft-Windows-Deployment/RunSynchronous`, error `0x80220005`. The bootstrap log directory was absent, consistent with rejection before the provisioning script ran.

The source generator embedded a **1,458-character** PowerShell encoded command in `RunSynchronousCommand/Path`. Microsoft's documented maximum is **259 characters** ([Path reference](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/microsoft-windows-deployment-runsynchronous-runsynchronouscommand-path)). This automation defect was confirmed by both live console logs and read-only offline inspection.

On 2026-10-21, the source generator was repaired to use a short launcher (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File configure-windows.ps1`) and fail generation if the rendered path exceeds 259 characters. The regenerated answer file is valid XML; its rendered launcher is **78 characters**. A server-side Kubernetes Secret dry run passed without displaying credentials. The guest script now resolves the attached seed-media root and preserves Panther logs after provisioning.

A sparse recovery copy of the stopped failed disk was created at the outer VM path `.../disk.img.recovery-2026-10-21`, size verified, SHA-256 `2f43a5008926bbc6b2636a990af407bfcb46f779d04a963f305c99d892980335`. Read-only inspection of the copy confirmed a 39.2 GiB Windows partition and 786 MiB WinRE partition, existing `C:\Windows\Panther\unattend.xml`, the oversized encoded command in `setuperr.log`, and no bootstrap log directory. This confirms Windows cached and rejected the old answer file; updating the Secret alone is not a safe in-place resume.

Relevant tracked files:

- [Answer-file generator](../scripts/30-create-kubevirt-vms/prepare-windows-unattended.mjs): `bootstrap` and `encoded` construct the oversized command.
- [XML template](../scripts/30-create-kubevirt-vms/windows-unattend.xml): `specialize` / `Microsoft-Windows-Deployment` / `RunSynchronousCommand/Path`.
- [Guest provisioning script](../scripts/30-create-kubevirt-vms/configure-windows.ps1): drivers, QEMU agent, and OpenSSH steps are not verified on this installation.
- [Host orchestrator](../scripts/30-create-kubevirt-vms/setup-windows-server.sh) and [approved JSON config](../scripts/30-create-kubevirt-vms/windows-server.json).

Local diagnostic screenshots are in ignored `work/windows-status.png`, `work/windows-diagnostic-console.png`, `work/windows-setup-errors.png`, and `work/windows-login-error.png`. They are diagnostic evidence, not completed-OS verification. Do not publish generated answer media or credentials.

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

## Session Handoff - 2026-11-04

### Work Completed

- The host kubeconfig had the loopback endpoint `https://127.0.0.1:6443`, so host-side `virtctl start` calls failed. It was re-exported from the running outer VM and now points to `https://192.168.122.162:6443`. Rediscover the address after future power/network changes; do not rerun the full task 20 bootstrap solely to refresh this file.
- The outer VM lost its default route after OVN bridged its uplink. The guarded repair helper was extended to detect a missing NIC on the unique bridge named by OVN's `ovn-bridge-mappings`, restore the DHCP address/default route, and verify SSH. It restored `enp1s0` on `brenp1s0`.
- The stale Windows VMI had failed with `UnexpectedAdmissionError` for `vhost-net`. After verifying the VM was Stopped and the VMI owner UID matched the VM UID, only the failed VMI was normally deleted. The Windows VM, disks, and PVCs were preserved.
- A task 20 bootstrap rerun was started while trying to refresh the kubeconfig, then interrupted during the OVN source clone before Helm or Kubernetes apply. During recovery, the OVS/OVN node pods were restarted, and stateless service pods were recreated to restore their OVS ports. The full cluster check and host-side `virtctl version` now pass. No full lab reset was run.
- `netpol-server-rocky` and `netpol-client` were started. Rocky's key-based access/OS verification passed. Ubuntu's VMI is Ready and its guest agent is connected, but the key-authenticated SSH probe to port 22 was refused; `setup-ubuntu-client.sh --verify` was interrupted while waiting and did not pass.

### Current Verified State

| Component | State at handoff |
| --- | --- |
| Outer `lab-k8s-01` | Running at `192.168.122.162`; OVN uplink and default route repaired for this boot |
| K3s / OVN / KubeVirt / CDI | Full pinned cluster health check passes; host `virtctl` reaches server v1.9.1 |
| `netpol-server-rocky` | Running; OS, network, guest agent, and key SSH verification passed; test listeners not configured |
| `netpol-client` | Running VMI, Ready, guest agent connected; SSH on port 22 refused, cloud-init/SSH verification incomplete |
| `netpol-server-windows` | Stopped; Windows account/OS state remains unverified |
| `netpol-test` data | VM definitions and PVCs preserved; no NetworkPolicies were applied during this session |
| Task 35 | Isolation test not yet run; no result should be claimed |

### Expected Resume Steps

1. Run `bash scripts/check-lab-progress.sh` and `bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh`. Do not run cleanup or reset before resuming.
2. Resolve Ubuntu SSH/cloud-init before treating it as a usable test client. Inspect its console/cloud-init state; rerun `bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --verify` only after SSH is available. The interrupted verifier may be run again; it does not delete disks.
3. Configure the Rocky test service as described in [task 35](../scripts/35-verify-kubernetes-isolation/README.md). The task 30 VM exposes TCP 8080 and 8081; start listeners inside Rocky, then verify baseline requests from Ubuntu before applying policy.
4. Only after baseline connectivity succeeds, apply the narrow default-deny and client/server allow policies described by task 35. Record actual allow/deny traffic results. Do not use the legacy `run-isolation-test.sh` against these installed VMs.
5. Keep Windows stopped until its OS/account, drivers, and test service are verified. Test Windows in a separate run; the full matrix is not complete until then.

Tracked changes from the recovery include the root README, the progress and cluster health diagnostics, and `scripts/20-install-k3s-kubevirt/repair-guest-network.sh`. These do not replace the runtime checks listed above.

## Installation History

Subsequent guest installation update, 2026-10-20: Rocky installation completed per the user; its full stop/start and disk-first VMI configuration were verified. A VNC capture confirmed Rocky Linux 10.2 (Red Quartz) at the `netpol-server-rocky login:` prompt. Login and networking were subsequently confirmed by the user and scripted checks below.

Subsequent access automation update, 2026-10-20: the existing administrator authenticated directly in the terminal and the bootstrap completed. `labadmin` now has its dedicated SSH key and passwordless lab sudo; the private key stays in ignored `work/`. Independent noninteractive checks passed for Rocky 10.2, XFS/LVM root, DHCP address `10.0.2.2/24`, default route via `10.0.2.1`, DNS, outbound HTTPS, sudo, SSH, and the guest agent. Effective SSH policy confirms public-key authentication enabled and password, keyboard-interactive, and root SSH login disabled. Kubernetes reports `AgentConnected=True` and Rocky OS details. Rocky's masquerade interface forwards TCP 22 alongside 8080/8081; the guarded template patch and graceful restart preserved disk-first boot and the installed disk. A fresh unattended installation/Kickstart workflow is not implemented by these post-install scripts.

This is the durable project checkpoint. Run `bash scripts/check-lab-progress.sh` for a fresh inventory before resuming; live state may have changed since this note was written. If the managed outer VM is powered off, the checker prompts for permission to start it and waits up to five minutes for networking and SSH. Without approval it stops and reports verification as incomplete. Update this file whenever a task completes or a new blocker is found.

## Where We Are

As of 2026-11-04, the cluster is healthy after recovery, Rocky and Ubuntu are running, and Windows remains stopped. The latest live state and recovery evidence are in [Session Handoff - 2026-11-04](#session-handoff---2026-11-04). Windows' earlier unattended setup failure and rejected saved password remain unresolved; the historical October 21 evidence below is not a current Windows verification.

| Task | State |
| --- | --- |
| 00 Host preflight | Passed in the 2026-11-04 recovery session |
| 10 Outer VM `lab-k8s-01` | Running; disk expanded 100 → 130 GiB |
| 20 K3s / OVN / KubeVirt / CDI | Full pinned health check passed after restoring the OVN/OVS uplink and pod attachments |
| 25 Guest media | Done; ISOs staged and uploaded |
| 30 KubeVirt test VMs | Rocky and Ubuntu Running; Windows Stopped; VM disks/PVCs preserved |
| 30 Guest OS installs | Rocky verified; Ubuntu SSH/cloud-init verification incomplete; Windows account/OS unverified |
| 35 Isolation tests | Not started; Rocky service not configured and Ubuntu client SSH not verified |
| 40 Azure/NSX static checks | Not started |
| 45 Monitoring dashboards | Previously installed; verify after any future cluster/network recovery |

**Next: resolve Ubuntu's SSH startup, configure and baseline the Rocky test service, then follow task 35.** Do not apply deny policies until baseline connectivity works. Do not clean/reset as a routine resume step.

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

**Next session: keep the lab stable, then design the microsegmentation policy plane in `microsegmentation-iac/`.** The Linux guests are installed and verified; Windows is still unverified. See [the new policy plan](../microsegmentation-iac/README.md) for the long-lived contract, audit fields, and platform adapters.

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
- Rocky server `netpol-server-rocky` is installed and currently Running. The guarded disk-first boot and OS/network/key-access checks passed again on 2026-11-04. TCP test listeners on ports 8080 and 8081 are not configured.
- Ubuntu client `netpol-client` is installed on the project-owned `netpol-client-cloud-disk` (10 GiB) and currently Running. Its VMI is Ready and the guest agent is connected, but a 2026-11-04 key-based SSH probe to port 22 was refused. The verification helper was interrupted while waiting; inspect cloud-init/sshd before relying on Ubuntu as the test client. Original disk, DataVolume, and ISO PVC remain preserved.
- Windows server `netpol-server-windows` is Stopped. Its account/credential and OS state remain unverified; the saved password was previously rejected at login. Its original VirtIO disk and all Windows PVCs remain preserved. See the pause handoff for the unattended setup defect and recovery copy.
- Replaced the schema-1 `latest` VirtIO driver image with the official amd64 build `20261020_bb5dc762db-amd64`, pinned as `quay.io/kubevirt/virtio-container-disk@sha256:06a32bc8a4d84d2d8d86ef06ba92dad00d78d1b34cec2ee48e17a2fbe438a094`. The registry manifest is OCI schema 2, and the real Windows boot check passed.
- The stale failed Windows VMI was removed through normal deletion after verifying its controlling VM UID. The VM definition, all disks, installer PVCs, and DataVolumes were preserved. Task 30 now uses infrastructure-only preflight so it can recover failed workload launchers without weakening the default full cluster check.
- All three original guest disk DataVolumes report `Succeeded`, and all seven disk/installer/cloud PVCs are bound. The Ubuntu cloud-image upload and boot were validated end to end. The original disks and media remain preserved.
- Outer-guest `/` had about 84 GiB free at the latest check, near task 30's 84 GiB guard. Recheck capacity before importing more images or starting Windows work.
- SSH is reachable at `192.168.122.162`, and a fresh guest DNS lookup of `quay.io` succeeded. Rediscover the address after future power cycles rather than assuming it is unchanged.

## Resume Order

1. Read the [2026-11-04 session handoff](#session-handoff---2026-11-04), then run the progress checker and full cluster health check. Rediscover the outer VM address; its DHCP lease may change.
2. Diagnose Ubuntu's SSH refusal and complete its cloud-init/key-access verification without replacing its installed disk.
3. Start the documented temporary Rocky listeners, then confirm allowed-port and negative-control baseline requests from Ubuntu before applying any NetworkPolicy.
4. Follow task 35's manual policy matrix and record observed packet results, component versions, guest versions, labels, addresses, and test revision. No policy test result is currently recorded.
5. Keep Windows stopped until its installed OS, credentials, drivers, and test service are independently verified. Do not use the legacy installer/test runner or task 90 cleanup for routine recovery.

## Optional Rocky Desktop

The separate JSON-configured [task 32 desktop](../scripts/32-rocky-desktop/README.md) was provisioned unattended on 2026-10-20 after capacity and package checks. Rocky 9 was selected with user approval because the proposed XFCE/xrdp packages were available in EPEL 9, not the checked EPEL 10 listing. This does not change the installed Rocky 10 test server.

- Namespace/VM: `rocky-desktop`; disk: `rocky-desktop-disk` (30 GiB); 4 vCPUs and 6 GiB RAM. Configuration: [rocky-desktop.json](../scripts/32-rocky-desktop/rocky-desktop.json).
- Rocky 9.8 cloud-init completed without errors. Independent checks passed for XFCE, Firefox, xrdp/xorgxrdp, LightDM, SSH, guest-agent service, and enforcing SELinux.
- VNC screenshot confirmed the graphical login screen. Firefox successfully rendered an HTTPS page as non-admin user `desktop`.
- xrdp listens only on the guest loopback address. SSH tunnel `127.0.0.1:13389` reached successful RDP security negotiation; no public RDP port or Kubernetes Service was created.
- Admin `labadmin` uses a dedicated ignored private key and lab passwordless sudo. The separate `desktop` user's password was set privately, and the user confirmed an interactive RDP session. Intentional logout returned FreeRDP code `12` (`ERRINFO_LOGOFF_BY_USER`); xrdp remained active. The server certificate fingerprint was matched through trusted SSH.
- Existing Rocky, Ubuntu, and Windows resources were not modified. This optional desktop is outside the three-guest isolation matrix; include its memory/disk use in later capacity planning.

## Microsegmentation IaC Plan

The long-lived policy design now lives in [microsegmentation-iac](../microsegmentation-iac/README.md). It defines the shared policy contract, change-record mapping, diff/reportability, and platform adapters for Kubernetes, Azure NSG/VNet, and VMware NSX. Azure and NSX remain designed targets; they are not implemented or deployed.

## Recovery Notes

- During Ubuntu cloud-image setup, outer-guest SSH lost its address/default route due to the known OVN issue. The existing guarded runtime repair restored it; this is not a new persistent network fix. CDI also required an explicit `cdi.kubevirt.io/storage.bind.immediate.requested=true` annotation for an existing PVC upload. The new script sets this, safely retries only owned/inactive incomplete cloud disks, and tracks both local and remote upload forwarders for cleanup.
- For missing SSH after a lease expires, use `scripts/20-install-k3s-kubevirt/repair-guest-network.sh --diagnose`; the cluster checker also attempts the guarded runtime repair. It is not persistent across reboot.
- To expand the outer VM disk, use `bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh <total-size-gib>`. Do not run `qemu-img resize` against the active disk.
- Task 30 failures may leave PVCs, DataVolumes, VMs, or VMIs behind. The creator preserves persistent resources and only removes terminal failed VMIs after verifying ownership. Inspect the live state and follow the resume recommendation rather than deleting the namespace or rerunning cleanup blindly.
- After each completed guest installation, use `bash scripts/30-create-kubevirt-vms/boot-installed-disk.sh <vm-name>` with the guest fully stopped. The helper refuses existing VMIs and unexpected ownership/configuration, preserves media and PVCs, and leaves the guest stopped for an explicit start. Use `--dry-run` to preview without changing resources.

Current time is 21 Oct 10:47 PM

look in the doco/images folder for the windows loggin. Rename the files to consitent with what it is.
Theis was my last prompt
"The password it failing. also make the password shorted an easier to type, as I can't paste the password into the logon screen in vnc.
Either provde a remote access that I can paste the password in on make it smaller and easier to enter."

Note for the next session: add explanatory comments to the task scripts so a human can follow the flow more easily. Do not change script behavior; clarify variable names and concepts where helpful.