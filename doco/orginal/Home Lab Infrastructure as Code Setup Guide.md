# **Home Lab Infrastructure as Code Setup Guide**

# **Software Download Links and Prerequisites**

* **K3s (Lightweight Kubernetes Distribution)**  
  * Download & Quickstart: [k3s.io](https://k3s.io)  
  * Installation Command: `curl -sfL https://get.k3s.io | sh -`  
* **KubeVirt Operator & CLI (virtctl)**  
  * Documentation & Releases: [kubevirt.io](https://kubevirt.io) / [github.com/kubevirt/kubevirt/releases](https://github.com/kubevirt/kubevirt/releases)  
  * Deployment Spec: `kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml`  
* **Terraform CLI & Providers**  
  * Download Terraform: [developer.hashicorp.com/terraform/downloads](https://developer.hashicorp.com/terraform/downloads)  
  * Terraform Registry (VMware NSX Provider): [registry.terraform.io/providers/vmware/nsxt/latest](https://registry.terraform.io/providers/vmware/nsxt/latest)  
* **VMware vSphere / ESXi & NSX Manager**  
  * VMware Customer Connect / Broadcom Support Portal: [support.broadcom.com](https://support.broadcom.com)

# **Virtual Machine Setup and Nested Virtualization Configuration**

## **Host Hardware Baseline Constraints**

* **RAM:** 64 GB  
* **CPU:** 16 Cores  
* **Strategy:** Stagger VM start times and closely monitor host resource allocation to prevent memory overcommitment when running K3s, KubeVirt, and VMware NSX Manager simultaneously.

## **Enabling Nested Virtualization**

### **1\. Linux Host (KVM / QEMU)**

Verify and enable nested virtualization on the Linux KVM hypervisor host:

**For Intel Processors:**\# Check if nested virtualization is enabled (returns Y or 1\)

cat /sys/module/kvm\_intel/parameters/nested

\# If disabled, enable via module configuration:

echo "options kvm-intel nested=1" | sudo tee /etc/modprobe.d/kvm-intel.conf

sudo modprobe \-r kvm\_intel

sudo modprobe kvm\_intel

**For AMD Processors:**\# Check if nested virtualization is enabled (returns Y or 1\)

cat /sys/module/kvm\_amd/parameters/nested

\# If disabled, enable via module configuration:

echo "options kvm\_amd nested=1" | sudo tee /etc/modprobe.d/kvm-amd.conf

sudo modprobe \-r kvm\_amd

sudo modprobe kvm\_amd

### **2\. Virtual Machine CPU Passthrough**

Ensure guest virtual machines exposed to K3s and KubeVirt have host CPU feature passthrough enabled:

* **virt-manager / virsh XML:** Set CPU mode to `host-passthrough`.

\<cpu mode='host-passthrough' check='none'/\>

* **KubeVirt Hardware Passthrough Verification:**  
  Inside the guest VM / K3s node, verify hardware virtualization availability:

egrep \-c '(vmx|svm)' /proc/cpuinfo

If the output is greater than 0, nested virtualization is active and ready for KubeVirt virtual machine workloads.