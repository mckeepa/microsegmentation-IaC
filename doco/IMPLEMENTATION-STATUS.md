# Implementation Status

## Session Handoff - 2026-11-08

This is the latest checkpoint and supersedes the 2026-11-05 handoff below. **Night of 2026-11-08: the lab was resumed, repaired, and shut down cleanly again for a laptop power-off.** The evening resume exposed a root cause: Ubuntu netplan guests pin the NIC MAC from first boot, but the KubeVirt masquerade MAC changes with the launcher pod IP on every restart, leaving the guest with no IPv4 (`web-ubuntu-01` hung the fleet SSH wait with `dialing VM: dial tcp :22: connect: connection refused`). The live guest was repaired through the QEMU guest agent, both Ubuntu cloud-init builders now match the NIC by name, and the SSH wait heartbeat now prints the real error instead of `exit status 255`. **`netpol-client` still has the old MAC-pinned netplan on its disk and needs the one-time guest-agent repair in [scripts/README.md](../scripts/README.md#resume-after-an-interruption) on its next start.** At shutdown the three running guests (`rocky-desktop`, `web-ubuntu-01`, `db-rocky-01`) were stopped gracefully (all VMIs gone; `netpol-client` was already stopped) and `lab-k8s-01` completed a graceful `virsh shutdown` in about 100 seconds. No installation was in progress. Resume with `bash scripts/resume-lab.sh --start-vm --start-fleet --start-desktop`; reopen tunnels afterward and regenerate the Headlamp token (`bash scripts/45-monitoring-dashboard/dashboard-permissions.sh token`; the saved one expires after an hour).

### State at Handoff

| Component | Latest evidence |
| --- | --- |
| Outer `lab-k8s-01` | Running at `192.168.122.123`; disk live-resized 100 → 130 GiB (about 100 GiB free on the guest root afterward) |
| K3s / OVN / KubeVirt / CDI | Healthy after route repair; all infrastructure pods Running/ready (see recovery note below) |
| `rocky-desktop` | Running and Ready; `--verify` passed (Rocky 9.8, XFCE, Firefox, xrdp, SELinux enforcing, loopback-only RDP); the user set the `desktop` password privately and confirmed a working tunneled RDP session with `xfreerdp3 ... /d:` |
| `netpol-test` namespace | Created by the first-build creator; all three installer ISOs uploaded; `netpol-server-rocky`, `netpol-client`, and `netpol-server-windows` VM templates created and boot-checked (each VMI reached Running, then stopped) |
| `netpol-client` (Ubuntu) | Unattended cloud-image apply and an independent re-verify both printed `PASS Ubuntu unattended setup and key-based administration`; Ubuntu 24.04.5, key-only SSH, passwordless lab sudo, guest agent connected; VMI Running and Ready |
| `netpol-server-rocky` / `netpol-server-windows` | Installer templates only on this rebuilt lab; **no OS is installed** on their fresh disks (the previous installed disks were deleted in the 2026-11-05 full reset); both stopped with installer-first boot |
| VM fleet (task 34) | `bash scripts/34-vm-fleet/setup-vm-fleet.sh --apply` provisioned and verified `web-ubuntu-01` (Ubuntu 24.04, `seg-web`) and `db-rocky-01` (Rocky 9, `seg-db`) unattended end to end; both printed their `PASS fleet VM ...` lines on apply and again on an independent `--verify` |
| Dashboards (task 45) | Reinstalled after the reset: Cockpit (outer VM, loopback `9090`) and Headlamp v0.46.0 (`lab-dashboard`, read-only RBAC); `--verify` passed; fresh Cockpit password and Headlamp token regenerated into ignored `work/`; both returned HTTP 200 through the host tunnels (`localhost:19090`, `localhost:18080`) |
| Lab Switchboard | Rebuilt (`--install-builder`, Podman image `lab-switchboard:0.1.0`) and redeployed; rollout and RBAC checks passed; `/healthz` returned `{"healthy":true}` at `localhost:18088`; new portal password in ignored `lab-switchboard/.local/admin-password`; its configured namespaces remain `netpol-test` and `rocky-desktop` (fleet namespaces not yet in `config/lab.json`) |
| Cockpit on fleet VMs | Both blueprints now install Cockpit bound to guest loopback only; `setup-vm-fleet.sh --cockpit <name>` opens a per-VM tunnel (verified HTTP 200 for `web-ubuntu-01` at `https://127.0.0.1:19091`); the two existing fleet VMs were retrofitted over SSH; login needs the `--set-password` OS password |
| Isolation tests | Not run on the rebuilt environment |

### Fixed This Session

- **Desktop host-key blocker resolved safely.** The guest ED25519 fingerprint (`SHA256:MmFdXXrtpijwk4k48bVSDoojlzH6DaIMD+fVvho6xrk`) was independently verified by `ssh-keyscan` from inside `lab-k8s-01` to the launcher pod IP before removing only the stale `vmi.rocky-desktop.rocky-desktop` entries from the laptop's global `~/.ssh/known_hosts` (backup retained). Host-key checking stayed enabled. The same verified procedure later removed stale `vmi.netpol-client.netpol-test` entries left by the pre-reset lab.
- **Root cause of silent SSH waits fixed.** `virtctl ssh --known-hosts` is ignored by its local-ssh wrapper, so connections consulted the global known-hosts file. Both `setup-rocky-desktop.sh` and `setup-ubuntu-client.sh` now pass `-o UserKnownHostsFile` so the project's pinned `work/*_known_hosts` files are authoritative.
- **Wait-loop visibility added.** Both scripts now print a heartbeat every 30 seconds (elapsed time, VMI phase, and the most recent SSH error) plus stage markers, so a host-key or boot failure is visible within seconds instead of a silent multi-minute wait.
- **OVN route loss recurred and was repaired.** After the outer VM's overnight reboot, the default route was missing again; CDI and KubeVirt operator/controller pods crash-looped for about ten hours with `dial tcp 10.96.0.1:443 ... network is unreachable`. The guarded runtime repair restored the route and every pod recovered without manual deletion. This remains a per-boot runtime repair, not a persistent fix.
- **Docs updated.** The Rocky desktop is now documented as a standard lab component (no longer "optional") across the README, design, setup, operations, and task docs; task 32 gained a start → verify → set-password → tunnel → connect quick start, an `/d:`-based FreeRDP command, and an "RDP from Another Machine" SSH-chaining section.
- **Shared library extracted.** Duplicated plumbing (outer-VM guards, IP discovery, remote kubectl, guest SSH with pinned known-hosts, heartbeat SSH waits, image fetching, CDI upload tunnels) now lives in `scripts/lib/common.sh`. Refactored onto it: `setup-rocky-desktop.sh` and `setup-ubuntu-client.sh` (both re-verified with their `PASS` lines), `create-test-vms.sh` and `boot-installed-disk.sh` (re-tested with `--dry-run`), `setup-windows-server.sh` (`--plan` re-tested), and `setup-rocky-access.sh` (syntax-checked only; its `--verify` needs an installed Rocky 10 guest, which does not exist on this rebuilt lab). The Windows and Rocky-access `virtctl ssh` helpers also received the known-hosts pinning fix.
- **VM fleet implemented (new task 34).** A single `scripts/34-vm-fleet/fleet.json` declares scalable test VMs from approved blueprints (`ubuntu-server`, `rocky-server` cloud images) with name/hostname, CPU, memory, disk, microsegmentation labels, forwarded ports, runState, owner, and purpose. Namespaces derive from the `app` label (`seg-<app>`). The manager (`setup-vm-fleet.sh --plan/--apply/--verify/--status/--ssh/--start/--stop/--set-password/--cockpit`) is create-and-reconcile only and never deletes resources. Windows/Rocky 10 remain outside the fleet until a verified unattended path exists.
- **VM inventory and resume tooling added.** Read-only `scripts/list-vms.sh` shows every nested VM's status (colored), cluster-reachable IP, sizing, forwarded `PORTS`, `ACCESS` methods, and labels, with `-l` label filters. `scripts/resume-lab.sh` is the one-command restart recovery: outer VM start with approval, SSH wait, guarded cluster check, pod-recovery wait, inventory, and optional `--start-fleet`/`--start-desktop`; verified against the live lab.
- **Access documentation centralized.** The main README gained a Dashboard Quick Access table and links to the monitoring docs; `scripts/README.md` has the VM Access guide (discover with `list-vms.sh`, then connect) and the shared-library section. Morning work was committed as `0f778f4`; the afternoon dashboard/fleet-cockpit/resume changes are in the working tree.

### Resume Next Session

1. After any laptop or outer-VM restart, run the one-command resumer from the repository root (add `--start-vm --start-fleet --start-desktop` to also power things on). It handles the outer VM start, SSH wait, the guarded OVN route repair via the task 20 checker, pod crash-loop recovery, and prints the inventory and next commands.

   ```sh
   bash scripts/resume-lab.sh
   ```

   Dashboard tunnels never survive a restart; reopen them and regenerate the Headlamp token (1-hour lifetime).

   ```sh
   bash scripts/45-monitoring-dashboard/access-dashboards.sh --host
   bash lab-switchboard/scripts/access.sh
   ```

2. For deeper diagnosis run the progress checker and the task 20 cluster checker directly.

   ```sh
   bash scripts/check-lab-progress.sh
   bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh
   ```

3. Scale additional test servers by adding entries to `scripts/34-vm-fleet/fleet.json` and re-running `--apply`; see the [task 34 guide](../scripts/34-vm-fleet/README.md).
4. For the three-guest isolation matrix, Rocky 10 and Windows still need OS installation on this rebuilt lab (manual ISO path for Rocky; the repaired unattended generator for Windows remains unverified end to end).

### Next Steps: Microsegmentation on the Common Config

The precondition (at least two running KubeVirt VMs) is exceeded, and the fleet provides the **common configuration** the policy work keys on: every fleet VM carries `app`/`tier`/`env` labels on both the VM and its launcher pod, lives in a namespace derived from `app` (`seg-web`, `seg-db`), and exposes only declared ports (`web-ubuntu-01`: 8080; `db-rocky-01`: 5432). Policies must select on those labels/namespaces, not addresses. Recommended order:

1. **Start test listeners** on the fleet VMs over SSH (for example `python3 -m http.server 8080` on `web-ubuntu-01`; a simple TCP listener on 5432 on `db-rocky-01`). A forwarded port with no listener proves nothing.
2. **Record the baseline**: from each VM, test the allowed direction (`web -> db :5432`), the reverse, and a negative control against an undeclared port, using the pod IPs from `scripts/list-vms.sh`. Capture source, destination, port, and result before any policy exists.
3. **Write the first policies in Git** under the [microsegmentation-iac](../microsegmentation-iac/README.md) contract: a default-deny ingress baseline in `seg-db`, plus the smallest allow rule admitting `app=web` pods/VMs to TCP 5432, and the required DNS/management flows. Remember the guest traffic traverses the launcher pod, so policies select the pod labels the fleet already applies.
4. **Apply via a reviewed change** (Argo CD is not installed; use reviewed direct `kubectl` per the operations guide), then rerun step 2 and record which flows changed. Both the allowed and the denied observation are required evidence; an un-enforced NetworkPolicy object proves nothing with this CNI until demonstrated.
5. Fold verified results into the [task 35 plan](../scripts/35-verify-kubernetes-isolation/README.md) format and update this checkpoint.

## End-of-Day Handoff - 2026-11-05

Work is paused at the user's request. This is the latest checkpoint and supersedes the older resume instructions below. No shutdown, restart, password reset, or host-key repair was performed while recording this handoff.

### State at Handoff

| Component | Latest evidence |
| --- | --- |
| Outer `lab-k8s-01` | Running and reachable over key-based SSH at `192.168.122.123`; fresh Ubuntu 24.04.5, 8 vCPUs, 24 GiB RAM, 100 GiB disk |
| K3s / OVN / KubeVirt / CDI | Task 20 bootstrap and full pinned cluster health check passed earlier today; not rerun at handoff |
| Optional `rocky-desktop` | Recreated after reset; currently Stopped, VMI `Succeeded`, launcher pod `Completed`; a user screenshot showed the graphical login screen earlier |
| Desktop login | Not verified; password-setting helper failed with a changed SSH host key before it could set a password |
| Task 30 test guests | No Ubuntu client, Rocky test server, or Windows VM currently present; `netpol-test` namespace absent |
| Dashboards / Switchboard | `lab-dashboard` and `lab-switchboard` namespaces absent after reset; prior deployment and credential instructions are historical |
| Isolation tests | Not run on the rebuilt environment |

### Desktop Access Blocker

- `bash scripts/32-rocky-desktop/setup-rocky-desktop.sh --set-desktop-password` exited with a changed-host-key error for `vmi.rocky-desktop.rocky-desktop`. The terminal identified a stale ECDSA entry in the laptop's `~/.ssh/known_hosts` at line 319 and reported ED25519 fingerprint `SHA256:MmFdXXrtpijwk4k48bVSDoojlzH6DaIMD+fVvho6xrk`. This new desktop fingerprint has **not** been independently verified; do not remove the entry or disable host-key checking blindly.
- The helper specifies a project known-hosts file, but the error names the global SSH file. Inspect the effective `virtctl`/local SSH options and known-hosts lookup before repairing the stale identity.
- Desktop VM administrator `labadmin` is key-only with a locked password and passwordless lab sudo. There is no default graphical password. The intended graphical user is `desktop`; select it instead of `labadmin` in the login dropdown and set its password directly in the terminal after SSH is repaired.
- The selected `.local/admin-password` reference in [Switchboard's historical checkpoint](../lab-switchboard/STATUS.md) is a portal-only credential relative to `lab-switchboard/`, not a VM password. Do not read, print, or reuse it for desktop login. Any retained host credential file does not prove its old service still exists.

### Resume Next Session

1. Run the progress checker, then the cluster health check. Rediscover the outer VM address after a host restart; do not assume the address above is permanent. A completed stopped desktop VMI is not a running desktop session.

   ```sh
   bash scripts/check-lab-progress.sh
   bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh
   ```

2. When ready to work on the desktop, start only that VM. Wait for the VMI to be Running and ready. Do not recreate or reupload its disk to fix access.

   ```sh
   KUBECONFIG="$PWD/work/kubeconfig-lab-k8s-01.yaml" work/virtctl-v1.9.1 start rocky-desktop -n rocky-desktop
   ```

3. Independently verify the desktop host key through a trusted console or guest-agent path, then repair only the confirmed stale known-hosts entry and check the helper's effective SSH options. Retry the administrator-shell helper.

   ```sh
   bash scripts/32-rocky-desktop/setup-rocky-desktop.sh --ssh
   ```

4. Set the desktop password in the user's own terminal. Enter the new password there, never in chat. After a successful password update, run the `--vnc` helper and log in as `desktop`, or use the documented `--rdp` tunnel. Graphical login remains unverified until that succeeds.

   ```sh
   bash scripts/32-rocky-desktop/setup-rocky-desktop.sh --set-desktop-password
   ```

5. Continue [task 25](../scripts/25-prepare-guest-images/README.md) media verification and [task 30](../scripts/30-create-kubevirt-vms/README.md) test-guest provisioning separately. Reinstall optional dashboards only as an explicit follow-up, not as recovery of an existing deployment.

After a laptop shutdown, assume GUI viewers and SSH/RDP tunnels have closed. Recheck VM states before reconnecting. Preserve the recreated desktop disk and generated host files; no further cleanup is needed to resume.

## Full Reset and Clean-Build Test - 2026-11-05

The user explicitly approved deleting and recreating the outer VM, including its disk and all nested guest data. This supersedes the earlier preservation and resume instructions below; those sections are historical evidence, not current inventory.

- Task 90 dry run verified the project ownership marker and selected only `lab-k8s-01` and `/var/lib/libvirt/images/lab-k8s-01.qcow2`. The guarded interactive cleanup completed after graceful shutdown, undefining the VM and deleting its disk and generated outer-VM connection files.
- All cluster resources, nested guest disks, the Windows recovery copy inside the outer disk, and installed dashboards were removed. Downloaded host media and other ignored host-side files were retained; this was not credential erasure.
- Host preflight passed after cleanup: 16 logical CPUs, 48 GiB available memory, 453 GiB free on the root filesystem, accessible KVM, and enabled nested virtualization.
- The first `bash scripts/20-install-k3s-kubevirt/setup-k3s-kubevirt.sh` run created a fresh 100 GiB disk and outer VM with 8 vCPUs and 24 GiB RAM, plus a new SSH key and autoinstall seed, but exited after SSH did not become ready within 20 minutes. That initial unattended run did not pass end to end.
- After the user reported the new base VM ready, the guarded task 10 helper started the existing stopped VM without replacing its disk. Ubuntu 24.04.5, key-based SSH, passwordless sudo, and root access to nested KVM were verified at `192.168.122.123`.
- The installed OS presented a changed SSH host key. Its ED25519 fingerprint was independently verified through the local QEMU guest agent before removing only the stale address entry from the project-specific known-hosts file. Host-key checking remained enabled.
- Task 20 was rerun on this base VM and printed `Lab cluster setup completed.` K3s `v1.36.5+k3s1`, OVN-Kubernetes `v1.4.0`, Helm `v3.22.1`, KubeVirt `v1.9.1`, and CDI `v1.66.1` were installed. The host kubeconfig was exported to ignored `work/kubeconfig-lab-k8s-01.yaml` with the current API endpoint.
- **Task 20 verification passed:** `bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh` exited successfully, checking pinned versions, custom-CNI settings, API TLS SAN, OVN CNI plugins/CIDRs/Helm settings, node readiness, and readiness of every pod. Three KubeVirt pods had one startup restart each but were all ready at verification.

At task 20 completion, no nested guests or optional dashboards had been recreated. The optional desktop was subsequently recreated; see the latest end-of-day handoff above. Tasks 25 and 30 remain the next test-workload stages.

This tests a fresh outer VM on an already prepared physical host with cached Ubuntu installation media. It does not certify a bare host without prerequisites, nor recreate or verify the task 25-35 workloads or optional dashboards.

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

1. Run the progress and cluster health checks. Do not run cleanup or reset before resuming.

   ```sh
   bash scripts/check-lab-progress.sh
   bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh
   ```

2. Resolve Ubuntu SSH/cloud-init before treating it as a usable test client. Inspect its console/cloud-init state; rerun the verifier only after SSH is available. The interrupted verifier may be run again; it does not delete disks.

   ```sh
   bash scripts/30-create-kubevirt-vms/setup-ubuntu-client.sh --verify
   ```

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

## Rocky Desktop

The separate JSON-configured [task 32 desktop](../scripts/32-rocky-desktop/README.md) was provisioned unattended on 2026-10-20 after capacity and package checks. Rocky 9 was selected with user approval because the proposed XFCE/xrdp packages were available in EPEL 9, not the checked EPEL 10 listing. This does not change the installed Rocky 10 test server.

- Namespace/VM: `rocky-desktop`; disk: `rocky-desktop-disk` (30 GiB); 4 vCPUs and 6 GiB RAM. Configuration: [rocky-desktop.json](../scripts/32-rocky-desktop/rocky-desktop.json).
- Rocky 9.8 cloud-init completed without errors. Independent checks passed for XFCE, Firefox, xrdp/xorgxrdp, LightDM, SSH, guest-agent service, and enforcing SELinux.
- VNC screenshot confirmed the graphical login screen. Firefox successfully rendered an HTTPS page as non-admin user `desktop`.
- xrdp listens only on the guest loopback address. SSH tunnel `127.0.0.1:13389` reached successful RDP security negotiation; no public RDP port or Kubernetes Service was created.
- Admin `labadmin` uses a dedicated ignored private key and lab passwordless sudo. The separate `desktop` user's password was set privately, and the user confirmed an interactive RDP session. Intentional logout returned FreeRDP code `12` (`ERRINFO_LOGOFF_BY_USER`); xrdp remained active. The server certificate fingerprint was matched through trusted SSH.
- Existing Rocky, Ubuntu, and Windows resources were not modified. This desktop is outside the three-guest isolation matrix; include its memory/disk use in later capacity planning.

## Microsegmentation IaC Plan

The long-lived policy design now lives in [microsegmentation-iac](../microsegmentation-iac/README.md). It defines the shared policy contract, change-record mapping, diff/reportability, and platform adapters for Kubernetes, Azure NSG/VNet, and VMware NSX. Azure and NSX remain designed targets; they are not implemented or deployed.

## Recovery Notes

- During Ubuntu cloud-image setup, outer-guest SSH lost its address/default route due to the known OVN issue. The existing guarded runtime repair restored it; this is not a new persistent network fix. CDI also required an explicit `cdi.kubevirt.io/storage.bind.immediate.requested=true` annotation for an existing PVC upload. The new script sets this, safely retries only owned/inactive incomplete cloud disks, and tracks both local and remote upload forwarders for cleanup.
- For missing SSH after a lease expires, run the network diagnoser; the cluster checker also attempts the guarded runtime repair. It is not persistent across reboot.

  ```sh
  bash scripts/20-install-k3s-kubevirt/repair-guest-network.sh --diagnose
  ```

- To expand the outer VM disk, use the resize helper. Do not run `qemu-img resize` against the active disk.

  ```sh
  bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh <total-size-gib>
  ```

- Task 30 failures may leave PVCs, DataVolumes, VMs, or VMIs behind. The creator preserves persistent resources and only removes terminal failed VMIs after verifying ownership. Inspect the live state and follow the resume recommendation rather than deleting the namespace or rerunning cleanup blindly.
- After each completed guest installation, boot the installed disk with the guest fully stopped. The helper refuses existing VMIs and unexpected ownership/configuration, preserves media and PVCs, and leaves the guest stopped for an explicit start. Use `--dry-run` to preview without changing resources.

  ```sh
  bash scripts/30-create-kubevirt-vms/boot-installed-disk.sh <vm-name>
  ```

Current time is 21 Oct 10:47 PM

look in the doco/images folder for the windows loggin. Rename the files to consitent with what it is.
Theis was my last prompt
"The password it failing. also make the password shorted an easier to type, as I can't paste the password into the logon screen in vnc.
Either provde a remote access that I can paste the password in on make it smaller and easier to enter."

Note for the next session: add explanatory comments to the task scripts so a human can follow the flow more easily. Do not change script behavior; clarify variable names and concepts where helpful.