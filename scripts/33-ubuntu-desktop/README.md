# Unattended Ubuntu GNOME Desktop

This desktop is a standard part of the lab, kept separate from the microsegmentation test guests. It uses its own `ubuntu-desktop` namespace, VM, disk, SSH key, and known-hosts file. It is a sibling of the [task 32 Rocky desktop](../32-rocky-desktop/README.md) and does not replace it or any test guest.

## Quick Start: Start the VM, Set the Password, Connect over RDP

The fastest path for an already provisioned desktop is the combined helper, which starts both desktops and opens both RDP tunnels in the background (first-time provisioning is covered under [Provision](#provision)):

```sh
bash scripts/start-desktops.sh
```

See the [desktop auto-start helper](../README.md#desktop-auto-start-helper) for details. The manual per-step flow mirrors task 32; run every command from the repository root in **physical-host terminals**. The outer `lab-k8s-01` VM must be running first.

1. **Start the desktop VM** (safe to skip if already running):

   ```sh
   export KUBECONFIG="$PWD/work/kubeconfig-lab-k8s-01.yaml"
   work/virtctl-v1.9.1 start ubuntu-desktop -n ubuntu-desktop
   ```

2. **Wait for it to be ready** — this prints progress and must end with the `PASS` line:

   ```sh
   bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --verify
   ```

3. **Set the `desktop` user's password** (first time only, or after you forget it). Type and confirm it at the interactive prompt; it is required for RDP login:

   ```sh
   bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --set-desktop-password
   ```

4. **Open the RDP tunnel in Terminal A** and leave it running (or use `start-desktops.sh`, which backgrounds it):

   ```sh
   bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --rdp
   ```

5. **Connect from Terminal B** with FreeRDP. `/d:` pre-sets an empty domain (local account), so the only prompt is `Password:` — type the password from step 3 (it is not echoed) and press Enter:

   ```sh
   xfreerdp3 /v:127.0.0.1:13390 /u:desktop /d: /dynamic-resolution /clipboard /cert:tofu
   ```

If RDP authentication fails repeatedly, the most likely cause is that step 3 was never run; the `desktop` account's password starts locked.

## Configuration

Edit [ubuntu-desktop.json](ubuntu-desktop.json) before the first apply. Defaults are Ubuntu 24.04 (noble), GNOME (`ubuntu-desktop-minimal`), Firefox, 4 vCPUs, 8 GiB RAM, a 40 GiB local-path disk, UTC, administrator `labadmin`, and desktop user `desktop`. The image URL and SHA-256 are pinned to the same Ubuntu cloud image the task 34 fleet uses, so a cached download is reused. Secrets are not stored in JSON; private keys and downloaded images are kept in ignored `work/`.

GNOME is heavier than the Rocky desktop's XFCE, hence the larger memory and disk defaults. The xrdp session runs the full Ubuntu GNOME session over Xorg; a `.xsessionrc` selects it and a polkit rule suppresses the colord authentication popup that otherwise appears in xrdp sessions. Firefox is the Ubuntu snap pulled in by `ubuntu-desktop-minimal`. This is a disposable lab, not a supported production desktop platform.

## Provision

Run from the repository root in the physical host's VS Code terminal:

```sh
bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --plan
bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --apply
```

Use `--config path/to/file.json` for a reviewed alternate configuration. Apply checks capacity and project ownership, creates a new disk only, verifies the image checksum, uploads it through CDI, and starts the cloud-init configured VM. No installer interaction or guest password is needed for provisioning. The GNOME package set is large; installation can take 20 minutes or more. Success requires cloud-init completion and the final `PASS Ubuntu GNOME desktop, browser, and loopback-only RDP services` message, not just a Running VMI.

The administrator uses key-only SSH and unrestricted passwordless sudo for this lab. The separate desktop user has no sudo privileges and initially has a locked password. Do not share the admin private key. Existing PVCs with unexpected ownership, image checksum, or size are refused; an attached OS disk is never reuploaded. Reapply reuses a recognized instance and verifies it; changed first-boot JSON settings do not reconfigure an existing installation automatically.

```sh
bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --verify
bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --ssh
```

While waiting for guest SSH, apply and verify print a heartbeat every 30 seconds. Guest SSH host keys are pinned in `work/ubuntu-desktop_known_hosts`; if the key changes, verify the new fingerprint through a trusted path before accepting it.

## Set Desktop Password

After provisioning, set the non-admin `desktop` user's password once:

```sh
bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --set-desktop-password
```

Type and confirm the password directly in the terminal. Never paste it in chat, JSON, command arguments, or Git. This password is for graphical/RDP login; SSH remains key-only and root SSH remains disabled. An account password must be set before RDP or the graphical console can authenticate that user.

## RDP Access

The security model is identical to the [task 32 RDP access](../32-rocky-desktop/README.md#rdp-access) design: xrdp listens only on the guest's `127.0.0.1:3389`, there is no Kubernetes Service or public listener, and the tunnel runs inside the authenticated SSH connection through the Kubernetes API. Only the local port differs: this desktop uses `127.0.0.1:13390` (Rocky uses `13389`).

```sh
bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --rdp
```

Connect an RDP client to `127.0.0.1:13390` as `desktop` with the password you set. The trust-on-first-use certificate guidance, the `ERRINFO_LOGOFF_BY_USER` logout behaviour, and the [RDP from another machine](../32-rocky-desktop/README.md#rdp-from-another-machine) SSH-chaining pattern from task 32 all apply unchanged — substitute port `13390`.

GNOME note: log in at the xrdp screen with the Xorg session. The session is the full Ubuntu GNOME desktop; if the first login after provisioning is slow, the snap-based Firefox may still be seeding.

## VNC Console

For the graphical console or recovery:

```sh
bash scripts/33-ubuntu-desktop/setup-ubuntu-desktop.sh --vnc
```

The console uses GDM/GNOME; log in as `desktop`. VNC access is mediated by Kubernetes, not a public VNC server in the guest. RDP and the console use separate graphical sessions; log out of one before switching to avoid session conflicts.

## Recovery

If the outer VM loses SSH due to the known OVN route problem, use task 20's `repair-guest-network.sh --diagnose` and its guarded `--repair` before retrying (`start-desktops.sh` attempts this automatically). This desktop is outside task 30's manual installer creator and task 35's three-guest test matrix.
