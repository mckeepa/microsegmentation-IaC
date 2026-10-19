# Lab Setup Tasks

Start from the [project README](../README.md) for project scope and the [lab prerequisites](../doco/LAB-SETUP.md) for host capacity. Each task folder contains its own step-by-step guide and task-specific scripts. The current task 20 bootstrap pins its CNI and component versions; check its guide before changing those pins.

## Task Guides

1. [Host preflight](00-host-preflight/README.md): confirm CPU, memory, disk, nested virtualization, and KVM access.
2. [Create the lab VM](10-create-lab-vm/README.md): provision the single outer Linux guest from the host with the managed libvirt script.
3. [Install K3s, OVN-Kubernetes, and KubeVirt](20-install-k3s-kubevirt/README.md): run the host orchestrator to provision or start the VM, bootstrap the stack, and export kubeconfig.
4. [Prepare guest images](25-prepare-guest-images/README.md): download Ubuntu and Rocky Linux images and stage the Windows Server evaluation ISO.
5. [Create KubeVirt test VMs](30-create-kubevirt-vms/README.md): create and boot-check Rocky, Ubuntu, and Windows guests in that order; OS installation follows.
6. [Verify Kubernetes isolation](35-verify-kubernetes-isolation/README.md): test allowed and denied flows across the configured Linux and Windows guests.
7. [Azure and NSX static checks](40-validate-infrastructure-targets/README.md): validate generated infrastructure plans without requiring both platforms to be available.
8. [Clean up the lab](90-cleanup/README.md): preview or remove the managed lab VM and generated state with `cleanup-lab.sh` before restarting from task 10.

The initial K3s and OVN-Kubernetes lab is a single-node proof of concept, not a production topology; runtime compatibility has not yet been demonstrated. Keep all guest data disposable until backup and recovery procedures are defined.