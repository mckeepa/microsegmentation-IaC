# Create the Lab VM

Return to the [project README](../../README.md) for project scope and the [lab setup reference](../../doco/LAB-SETUP.md) for the host snapshot and VM inventory. This task creates only `lab-k8s-01`, the outer QEMU/KVM guest.

## Before You Start

- Complete [host preflight](../00-host-preflight/README.md).
- Confirm the VM image directory has at least 150 GiB free.
- Install `curl`, `gpgv`, `sha256sum`, and the Ubuntu archive keyring if they are not already available.
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

## Resize the Existing VM Disk

Do not run `qemu-img resize` directly against the active VM disk; QEMU holds a write lock while the VM is running. The managed lab disk can be expanded online with libvirt's `blockresize`, then the guest partition, LVM physical volume, root logical volume, and filesystem are grown through QEMU guest agent.

Preview an increase to a total virtual size of 130 GiB, then apply it:

```sh
bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh 130 --dry-run
bash scripts/10-create-lab-vm/resize-lab-vm-disk.sh 130
```

The argument is the **new total disk size in GiB**, not the amount to add. The script only operates on the project-managed running `lab-k8s-01` VM and its `vda` QCOW2 disk, refuses shrinking, and requires 150 GiB free in the libvirt default storage pool. It uses the QEMU guest agent to grow the known Ubuntu LVM root layout. If the disk resize succeeds but guest filesystem growth fails, correct the reported guest issue and rerun with the same target; the script resumes without shrinking or re-resizing the virtual disk.

QCOW2 virtual capacity is thin-provisioned; expanding the virtual maximum does not immediately allocate the entire increase on the host. The host still needs enough physical storage for future guest writes. Check `df -h /` inside the guest afterward and retain at least the documented lab storage margin.

When libvirt reports an IPv4 DHCP lease, the provisioner prints a ready-to-copy `SSH login` command. It uses only the generated private key and a project-specific known-hosts file; log in as `labadmin`. The DHCP lease can appear before Ubuntu autoinstall has finished, so wait for the guest's first boot to complete before expecting SSH authentication to work. If no lease or login command is printed, check with `virsh -c qemu:///system domifaddr lab-k8s-01 --source lease`; once it appears, rerun the provisioner to print the command.

To let the helper start a stopped VM, wait for DHCP and SSH, prompt if the VM stops while waiting, and then open an interactive SSH session, run:

```sh
bash scripts/10-create-lab-vm/login-lab-vm.sh
```

The helper checks the libvirt ownership marker and uses the generated key with `IdentitiesOnly=yes`. It prints a status update every 30 seconds, asks whether to continue after 20 minutes without SSH, and never shuts down the VM when you exit the SSH session. If it reports SSH is not ready, check that Ubuntu autoinstall completed and that the VM accepts the generated key before retrying.

## Verify or Troubleshoot

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