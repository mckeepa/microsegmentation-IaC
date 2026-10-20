# Lab Setup Tasks

Start from the [project README](../README.md) for project scope and the [lab prerequisites](../doco/LAB-SETUP.md) for host capacity. Each task folder contains its own step-by-step guide and task-specific scripts. The current task 20 bootstrap pins its CNI and component versions; check its guide before changing those pins.

## Command Locations

Unless a block explicitly says otherwise, run it from the repository root on the **physical KVM host**. A prompt such as `labadmin@netpol-client` means you are inside a guest: run `exit` or open a new host terminal first. `work/virtctl-v1.9.1` is the host-side nested-VM client; `sudo k3s kubectl` runs inside the outer VM. A kubeconfig file alone does not install `kubectl`.

Use `--plan` or `--dry-run` before first-time provisioning where supported. Once guests are installed, use their `--verify`/`--ssh` access helpers instead of repeating creation. Ubuntu client and optional desktop settings are in JSON beside their setup scripts; the Rocky 10 server's ISO installation and Windows setup are still manual.

RDP and dashboard tunnels need a dedicated terminal left running. Start their client/browser from another terminal on the machine where the loopback tunnel is available. Logging out of SSH or a desktop does not power off the VM.

## Resume After an Interruption

Use the first-build path only for a new lab. Existing installations should enter through the checkpoint and inventory, not repeat the creator.

```mermaid
flowchart TD
   start[Start on the physical host<br/>Repository-root terminal]
   exists{Does the lab already exist?}
   fresh[Follow tasks 00 to 30<br/>Preflight, outer VM, cluster, media, guest resources]
   checkpoint[Read the implementation checkpoint]
   inventory[Run check-lab-progress.sh<br/>Approve outer-VM power-on if needed]
   inspect[Read WARN, BLOCKED and NEXT<br/>Inventory success is not deployment success]
   next[Use the matching task guide<br/>Verify, connect or recover existing resources]
   start --> exists
   exists -->|No - first build| fresh
   fresh --> checkpoint
   exists -->|Yes - resume| checkpoint
   checkpoint --> inventory --> inspect --> next
```

After a power loss or break, start here:

1. Read the checkpoint in [doco/IMPLEMENTATION-STATUS.md](../doco/IMPLEMENTATION-STATUS.md).
2. Run the progress checker from the repository root; it ends with a single `NEXT:` recommendation after inventory:

   ```sh
   bash scripts/check-lab-progress.sh
   ```

   If the project-managed outer VM is powered off, the checker asks permission to start it (default: no), then waits up to five minutes for networking and SSH before continuing. Declining, unavailable interactive input, or a failed start stops verification with a nonzero exit status. Other non-running VM states require manual attention. Apart from an approved VM start and SSH known-host recording, the checker only inspects state.

3. Follow that recommendation, then update the checkpoint file when a task completes or a new blocker is found.

Common recovery references:

- Outer VM disk too small: [resize the existing VM disk](10-create-lab-vm/README.md#resize-the-existing-vm-disk).
- Outer VM memory sizing: [inspect host/VM RAM and choose a next-boot allocation](10-create-lab-vm/README.md#change-the-vm-memory). This cannot add physical RAM or fix a host-memory shortage by itself.
- No SSH / DHCP lease expired: [task 20 troubleshooting](20-install-k3s-kubevirt/README.md#check-progress-and-troubleshoot) and `repair-guest-network.sh --diagnose`.
- Task 30 VM/PVC/image-pull failures: [task 30 troubleshooting](30-create-kubevirt-vms/README.md#troubleshooting).

## Task Guides

1. [Host preflight](00-host-preflight/README.md): confirm CPU, memory, disk, nested virtualization, and KVM access.
2. [Create the lab VM](10-create-lab-vm/README.md): provision the single outer Linux guest from the host with the managed libvirt script.
3. [Install K3s, OVN-Kubernetes, and KubeVirt](20-install-k3s-kubevirt/README.md): run the host orchestrator to provision or start the VM, bootstrap the stack, and export kubeconfig.
4. [Prepare guest images](25-prepare-guest-images/README.md): download Ubuntu and Rocky Linux images and stage the Windows Server evaluation ISO.
5. [Create KubeVirt test VMs](30-create-kubevirt-vms/README.md): create/boot-check guests, then use [JSON-configured unattended Ubuntu setup](30-create-kubevirt-vms/README.md#unattended-ubuntu-setup); Rocky and Windows have separate installation procedures.
6. [Verify Kubernetes isolation](35-verify-kubernetes-isolation/README.md): test allowed and denied flows across the configured Linux and Windows guests.
7. [Azure and NSX static checks](40-validate-infrastructure-targets/README.md): validate generated infrastructure plans without requiring both platforms to be available.
8. [Clean up the lab](90-cleanup/README.md): preview or remove the managed lab VM and generated state with `cleanup-lab.sh` before restarting from task 10.

Optional: [Monitoring and dashboards](45-monitoring-dashboard/README.md) adds Cockpit, Headlamp, laptop SSH tunnels, and a verified read-only/admin permission toggle. See the [monitoring inventory](../doco/MONITORING.md) for all lab monitoring tools.

The K3s/OVN-Kubernetes/KubeVirt lab has passed component-health and guest-boot checks. It is a single-node proof of concept, not a production topology; network-policy enforcement and OpenShift equivalence are not yet demonstrated. Keep all guest data disposable until backup and recovery procedures are defined.

## Optional Desktop

[Unattended Rocky desktop](32-rocky-desktop/README.md): JSON-configured separate Rocky 9/XFCE/Firefox VM with key-based SSH, a VNC console, and localhost-only tunneled RDP. It is not part of the three-guest isolation-test matrix and does not replace the existing Rocky server. Check capacity before running it alongside test workloads.