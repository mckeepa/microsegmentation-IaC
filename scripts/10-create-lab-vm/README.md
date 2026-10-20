# Create the Lab VM

Return to the [project README](../../README.md) for project scope and the [lab setup reference](../../doco/LAB-SETUP.md) for the host snapshot and VM inventory. This task creates only `lab-k8s-01`, the outer QEMU/KVM guest.

## Before You Start

- Complete [host preflight](../00-host-preflight/README.md).
- Confirm the VM image directory has at least 150 GiB free.
- Install `curl`, `gpgv`, `sha256sum`, and the Ubuntu archive keyring if they are not already available.
- Provisioning also requires `virsh`, `virt-install`, `xorriso`, `openssl`, and `ssh-keygen`, plus access to libvirt's system connection and its `default` network/storage pool. Install missing host packages before running the provisioner.
- Keep the initial VM on the libvirt NAT network. Do not bridge it onto the home LAN for the first test.

## Download Ubuntu Server

The provisioner downloads this ISO automatically when it is not already present. To fetch and verify it separately, from the project root run:

```sh
bash scripts/10-create-lab-vm/download-ubuntu-server.sh
```

The script downloads Ubuntu's signed 24.04 checksum list, verifies its signature with the installed Ubuntu archive keyring, selects the newest amd64 Server ISO listed, downloads it, and verifies its SHA-256 checksum. The ISO is saved under the shared root-level `work/` directory, which is ignored by Git.

Ubuntu 24.04.5 is the newest point release in the 24.04 LTS series, not the newest Ubuntu release overall. Ubuntu 26.04.1 is the current LTS as of 2026-10-18. Keep 24.04.5 for this initial K3s host until compatibility with the chosen K3s, KubeVirt, and CNI versions is confirmed on 26.04.1.

## Automated Provisioning

Run from the repository root. The first command previews the libvirt domain XML; the second downloads the verified Ubuntu ISO if needed and creates/configures the outer VM unattended:

```sh
bash scripts/10-create-lab-vm/provision-lab-vm.sh --dry-run
bash scripts/10-create-lab-vm/provision-lab-vm.sh
```

The provisioner creates `lab-k8s-01` with 8 vCPU, 24 GiB RAM, a dynamically allocated 100 GiB QCOW2 disk, `host-passthrough` CPU, and libvirt's `default` NAT network. Ubuntu autoinstall creates `labadmin`, installs OpenSSH and QEMU guest agent, enables key-only SSH using `work/lab-k8s-01_ed25519`, and grants that account passwordless sudo for lab automation. The NoCloud seed ISO and SSH keys stay in the Git-ignored `work/` folder.

On a fresh VM install, Ubuntu autoinstall runs `apt-get update` and `apt-get upgrade -y` after installing the base packages and before its final reboot. This refreshes the package index and applies available package upgrades once during creation. Rerunning the provisioner for an existing VM does not repeat the upgrade.

The script refuses to alter an unrelated VM with the same name. If this project's marked VM already exists, it starts it if stopped and otherwise leaves it running.

## Connect to the Outer VM

From the physical host at the repository root:

```sh
bash scripts/10-create-lab-vm/login-lab-vm.sh
```

This opens `lab-k8s-01`, the outer Ubuntu/K3s machine, not a nested test guest. Run `exit` to return to the physical host before running `bash scripts/...` commands. The helper checks the ownership marker, prompts before starting a stopped guest, and waits for DHCP/SSH using the generated key. It reports progress every 30 seconds and asks whether to continue after 20 minutes. Exiting SSH does not shut down the VM. If OVN routing prevents SSH, use the task 20 network diagnostics rather than repeatedly provisioning the VM.

## Resize the Existing VM Disk

Do not run `qemu-img resize` directly against the active VM disk; QEMU holds a write lock while the VM is running. The managed lab disk can be expanded online with libvirt's `blockresize`, then the guest partition, LVM physical volume, root logical volume, and filesystem are grown through QEMU guest agent.

Preview an increase to a total virtual size of 130 GiB, then apply it:

The existing lab has already been expanded to 130 GiB; these commands are for a new smaller VM or a reviewed capacity change, not a required resume step.

```sh
bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh 130 --dry-run
bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh 130
```

The argument is the **new total disk size in GiB**, not the amount to add. The script only operates on the project-managed running `lab-k8s-01` VM and its `vda` QCOW2 disk, refuses shrinking, and requires 150 GiB free in the libvirt default storage pool. It uses the QEMU guest agent to grow the known Ubuntu LVM root layout. If the disk resize succeeds but guest filesystem growth fails, correct the reported guest issue and rerun with the same target; the script resumes without shrinking or re-resizing the virtual disk.

QCOW2 virtual capacity is thin-provisioned; expanding the virtual maximum does not immediately allocate the entire increase on the host. The host still needs enough physical storage for future guest writes. Check `df -h /` inside the guest afterward and retain at least the documented lab storage margin.

## Change the VM Memory

Run this on the **physical host**, not in an SSH session inside the lab:

```sh
bash scripts/10-create-lab-vm/resize-lab-vm-memory.sh
```

The helper displays physical-host total, available, and completely free RAM, plus the outer VM's live and next-boot allocations. It prompts for the new **total GiB**, checks a minimum 24 GiB lab allocation and an 8 GiB host reserve, then asks for explicit approval. Enter at the size prompt cancels; the approval defaults to No. It verifies the project ownership marker and refuses unexpected hot-plug/NUMA/hugepage configurations.

Preview without changing memory; omit `32` to choose the size interactively:

```sh
bash scripts/10-create-lab-vm/resize-lab-vm-memory.sh 32 --dry-run
```

This helper changes **persistent next-boot settings only**. It does not hot-plug RAM, shut down the outer VM, or interrupt nested guests. Schedule a full outer-VM stop/start only after installations and guest writes finish, and after stopping nested workloads safely. All Kubernetes services and nested guests are interrupted by that outer-VM restart. Recheck host capacity before restarting; available memory can change after the script runs.

**A host preflight failure is not a guest-RAM shortage.** The 32 GiB preflight threshold is physical-host `MemAvailable`, intended to leave room before provisioning the lab. The running outer VM and other applications already consume host RAM. Increasing the VM's allocation cannot create physical RAM and may worsen that check after restart. Close unused host workloads, or review whether a provisioning check is appropriate for the running lab; do not add swap or weaken the check as a substitute for physical capacity.

## Verify or Troubleshoot

The provisioner prints a key-based `SSH login` command when a DHCP lease is available. That lease can appear before Ubuntu autoinstall finishes; wait for first boot before expecting authentication to work. For normal login, prefer the helper above instead of copying an old IP address. If no lease is available, use task 20's guest-agent diagnostics.

Inspect the VM and its DHCP address with:

```sh
virsh -c qemu:///system domstate lab-k8s-01
virsh -c qemu:///system domifaddr lab-k8s-01 --source lease
```

To update an already-created guest after logging in, run:

```sh
sudo apt-get update
sudo apt-get upgrade -y
```

The automated [task-20 orchestrator](../20-install-k3s-kubevirt/README.md) waits for this guest, connects using the generated SSH key, verifies nested KVM, and installs the cluster inside it. If the guest cannot see virtualization flags or access `/dev/kvm`, the bootstrap stops with an error; fix host/VM CPU passthrough before proceeding.

After `lab-k8s-01` is ready and K3s/KubeVirt are installed, prepare the nested test guest media using [task 25](../25-prepare-guest-images/README.md). Ubuntu is used as the client guest; Rocky Linux and Windows Server are separate KubeVirt server-test guests, not Virtual Machine Manager guests.