# Install K3s, OVN-Kubernetes, and KubeVirt

Return to the [project README](../../README.md) or [architecture](../../doco/ARCHITECTURE.md). This is run **from the physical QEMU/KVM host**. It provisions the outer Ubuntu VM first, then connects to that guest and installs the Kubernetes/virtualization stack inside it.

## Run the Automated Setup

Preview the outer VM definition and guest bootstrap plan:

```sh
bash scripts/20-install-k3s-kubevirt/setup-k3s-kubevirt.sh --dry-run
```

Run the full setup:

```sh
bash scripts/20-install-k3s-kubevirt/setup-k3s-kubevirt.sh
```

The host orchestrator runs preflight, calls [task 10](../10-create-lab-vm/README.md) to provision or safely start the project-managed `lab-k8s-01`, waits for the libvirt NAT DHCP lease and SSH, runs [`bootstrap-guest.sh`](bootstrap-guest.sh) inside the VM, then saves a mode-0600 kubeconfig to `work/kubeconfig-lab-k8s-01.yaml`. It does not create a VM directly on the physical host for K3s, and it refuses to adopt a same-named VM without this project's libvirt ownership marker.

The bootstrap currently pins K3s `v1.36.5+k3s1`, OVN-Kubernetes `v1.4.0` (image tag `release-1.4`), Helm `v3.22.1`, KubeVirt `v1.9.1`, and CDI `v1.66.1`. It verifies published SHA-256 digests for downloadable release assets, verifies the OVN source commit, and waits for the API, OVN, KubeVirt, and CDI readiness gates. Changing these versions requires rechecking their compatibility together.

Windows Server media remains an interactive Microsoft Evaluation Center download; it is not needed to bootstrap the cluster. Azure and VMware NSX deployment are separate tasks.

## Decisions Before Bootstrap

1. **CNI and policy controller. Recommended first candidate:** upstream OVN-Kubernetes, because OpenShift uses OVN-Kubernetes and the project's primary goal is to validate Kubernetes isolation against that network model. Before installation, verify that the chosen OVN-Kubernetes release supports the selected K3s/Kubernetes version and document its install procedure. Upstream OVN-Kubernetes on K3s is a closer dataplane comparison, but is not the same as Red Hat's packaged and managed OpenShift networking integration.
2. **K3s custom-CNI configuration:** if OVN-Kubernetes is selected, follow K3s custom-CNI guidance: start with Flannel disabled (`--flannel-backend=none`) and disable K3s's embedded network-policy controller (`--disable-network-policy`) when OVN supplies policy enforcement. Start from a fresh cluster; K3s warns that disabling its controller later does not automatically remove its installed iptables rules. Do not run two policy controllers against the same traffic.
3. **Fallback:** if a compatible, supportable OVN-Kubernetes-on-K3s version/configuration cannot be established, use bundled Flannel plus K3s's embedded policy controller to validate NetworkPolicy semantics and KubeVirt guest traffic. Record this as a functional fallback, not an OpenShift dataplane-parity result.
4. **K3s/Kubernetes and KubeVirt versions.** Choose a supported pair, then pin K3s, KubeVirt, and `virtctl` together. Do not independently select “latest” versions without checking their compatibility information.
5. **Storage. Recommended first pass:** use K3s's bundled `local-path` provisioner for this single-node, disposable lab. It stores data on the node and is not suitable for failover or live migration. Confirm free capacity and the default storage class.
6. **VM image import. Recommended first pass:** use a CDI release compatible with the chosen KubeVirt release and `virtctl image-upload` for local guest disks/media. Confirm a supported PVC access mode/storage class and the CDI upload-proxy access path before importing images.
7. **KubeVirt guest network. Recommended first pass:** use the primary pod network with `masquerade` binding for the test VMIs, then prove policy enforcement on guest-originated and guest-destined traffic. This is a test hypothesis, not a universal binding requirement; secondary/bridge/SR-IOV networks need a separate enforcement design.
8. **First test case.** Pin one TCP service port, labels, namespace, and expected allow/deny flows before writing policies. DNS allowances are needed if the guests resolve names under default-deny egress.

Argo CD is not required to prove the first isolation policy. For the first smoke test, apply reviewed manifests directly with `kubectl`; decide Argo CD bootstrap after the network path works. Azure/NSX provider plans are separate work and do not block this local K3s bootstrap.

Reference behavior: [OpenShift OVN-Kubernetes](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html/ovn-kubernetes_network_plugin/about-ovn-kubernetes), [K3s networking services](https://docs.k3s.io/networking/networking-services), [K3s custom CNI options](https://docs.k3s.io/networking/basic-network-options), [K3s storage](https://docs.k3s.io/add-ons/storage), [KubeVirt NetworkPolicy](https://kubevirt.io/user-guide/network/networkpolicy/), and [KubeVirt CDI](https://kubevirt.io/user-guide/storage/containerized_data_importer/).

## What the Automation Does

1. Validates host CPU/RAM/disk/KVM readiness and confirms the expected libvirt NAT/storage setup.
2. Creates `lab-k8s-01` with Ubuntu autoinstall, nested CPU passthrough, an SSH key, and NAT networking if the marked VM does not exist.
3. Waits for the guest's DHCP lease and SSH, then passes the guest IP to bootstrap so it is included in the K3s API certificate.
4. Installs K3s with Flannel, kube-proxy, and K3s's policy controller disabled for OVN; deploys the pinned OVN chart with the chart's pod/service CIDRs.
5. Installs pinned KubeVirt, CDI, and `virtctl`, waiting for their ready conditions.
6. Exports the host-usable kubeconfig to the ignored `work/` directory.

## Verify the Result

These commands use `kubectl`. The VM has `k3s kubectl` already installed; the physical host does not necessarily have the standalone `kubectl` executable. The exported kubeconfig does not install that executable.

### Run Inside the VM

After logging into `lab-k8s-01` with [the task 10 login helper](../10-create-lab-vm/README.md), run:

```sh
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
sudo k3s kubectl get kubevirt -n kubevirt
sudo k3s kubectl get cdi -n cdi
```

### Run From the Host

To run those checks locally without installing `kubectl` on the physical host, use the SSH helper. It discovers the current libvirt DHCP address and runs `k3s kubectl` inside the VM:

```sh
bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh
```

The checker prints node/pod details, then verifies the pinned K3s version and custom-CNI settings, OVN CNI files, CIDRs and Helm settings, readiness of all pods and the node, and the deployed KubeVirt/CDI versions. It exits `0` only when every check passes; any mismatch or unhealthy resource returns a nonzero exit status.

Alternatively, if standalone `kubectl` is installed on the host, use the exported kubeconfig:

```sh
KUBECONFIG=work/kubeconfig-lab-k8s-01.yaml kubectl get nodes -o wide
KUBECONFIG=work/kubeconfig-lab-k8s-01.yaml kubectl get pods -A
KUBECONFIG=work/kubeconfig-lab-k8s-01.yaml kubectl get kubevirt -n kubevirt
KUBECONFIG=work/kubeconfig-lab-k8s-01.yaml kubectl get cdi -n cdi
```

Prepare the test OS images with [task 25](../25-prepare-guest-images/README.md), then follow [Kubernetes isolation verification](../30-verify-kubernetes-isolation/README.md).

The dry run does not contact GitHub or mutate the host/guest. An actual run downloads pinned components and changes `lab-k8s-01`; errors stop the script, but cleanup/rollback of an already-installed cluster is a separate [task](../90-cleanup/README.md).

## Check Progress and Troubleshoot

Run these checks from a **second host terminal** while setup is running. Leave the original terminal alone so you can see the script's final output and exit status.

Check whether the host orchestrator and guest bootstrap SSH command are still active:

```sh
pgrep -af 'setup-k3s-kubevirt.sh|bootstrap-k3s-kubevirt'
```

If this prints processes, setup is still running; no output means it has exited. A running process alone does not mean the cluster is healthy. Setup succeeds only when the original command prints `Lab cluster setup completed.` and exits with status `0`. If it returns to the prompt without that message, check the command's exit status immediately with `echo "$?"`.

Check the node and all pods inside the guest. Query node and pod types separately; `kubectl get nodes,pods -A` is not valid syntax:

```sh
ssh -i work/lab-k8s-01_ed25519 \
	-o UserKnownHostsFile=work/lab-k8s-01_known_hosts \
	labadmin@192.168.122.111 \
	'sudo k3s kubectl get nodes -o wide; sudo k3s kubectl get pods -A'
```

To watch changes live, run either command in a second terminal and press Ctrl+C there when finished. This stops only the watch, not the setup command:

```sh
ssh -i work/lab-k8s-01_ed25519 -o UserKnownHostsFile=work/lab-k8s-01_known_hosts \
	labadmin@192.168.122.111 'sudo k3s kubectl get nodes -w'
```

```sh
ssh -i work/lab-k8s-01_ed25519 -o UserKnownHostsFile=work/lab-k8s-01_known_hosts \
	labadmin@192.168.122.111 'sudo k3s kubectl get pods -A -w'
```

A healthy cluster has node status `Ready`; OVN, CoreDNS, KubeVirt, and CDI pods should become `Running` with their ready counts satisfied. Persistent `Pending`, `CrashLoopBackOff`, `NotReady`, or repeated `Warning` events indicate a problem rather than normal progress.

For failure details, inspect recent events and describe the affected pod using its name and namespace from `get pods`:

```sh
ssh -i work/lab-k8s-01_ed25519 -o UserKnownHostsFile=work/lab-k8s-01_known_hosts \
	labadmin@192.168.122.111 \
	'sudo k3s kubectl get events -A --sort-by=.lastTimestamp | tail -n 30'
```

```sh
ssh -i work/lab-k8s-01_ed25519 -o UserKnownHostsFile=work/lab-k8s-01_known_hosts \
	labadmin@192.168.122.111 \
	'sudo k3s kubectl describe pod -n ovn-kubernetes <pod-name>'
```

For OVN controller logs, substitute the current `ovnkube-node` pod name shown by `get pods`:

```sh
ssh -i work/lab-k8s-01_ed25519 -o UserKnownHostsFile=work/lab-k8s-01_known_hosts \
	labadmin@192.168.122.111 \
	'sudo k3s kubectl logs -n ovn-kubernetes <ovnkube-node-pod> -c ovnkube-controller --tail=100'
```

Check the K3s service and its recent logs if the Kubernetes API is unavailable:

```sh
ssh -i work/lab-k8s-01_ed25519 -o UserKnownHostsFile=work/lab-k8s-01_known_hosts \
	labadmin@192.168.122.111 \
	'sudo systemctl is-active k3s; sudo journalctl -u k3s -n 100 --no-pager'
```

For host capacity or KVM issues, rerun [host preflight](../00-host-preflight/README.md). A setup exit status of `255` usually indicates the SSH session ended unexpectedly; check the guest's process, pod state, events, and logs above before retrying.

If OVN logs show `forbidden` errors for `system:serviceaccount:ovn-kubernetes:ovnkube-node`, check whether `ovnkube-identity` has any ready pods. Its upstream DaemonSet selector expects an empty `node-role.kubernetes.io/control-plane` label, while K3s sets that label to `true`. This bootstrap disables the identity subchart and identity mode so the OVN node ClusterRole binds directly to its ServiceAccount. Rerun task 20 to upgrade an existing OVN release with these settings.

If the run reaches OVN readiness but downloads fail with `Could not resolve host: github.com`, the OVN OVS bridge may have moved the default route off the interface that held the DHCP DNS setting. The bootstrap now writes `/etc/systemd/resolved.conf.d/90-lab-k3s-dns.conf` with the current default gateway as global DNS and verifies `github.com` resolution before downloading KubeVirt/CDI assets. The Helm lint message `[INFO] values.yaml: file does not exist` is informational when followed by `1 chart(s) linted, 0 chart(s) failed`; it is not the download failure.

If pod events report `failed to find plugin "loopback" in path [/opt/cni/bin]`, the standard CNI plugins are missing even though OVN's overlay plugin is present. The bootstrap installs Ubuntu's `containernetworking-plugins` package and copies its binaries into `/opt/cni/bin` before starting K3s. On an already-running VM, the equivalent recovery is `sudo apt-get install -y containernetworking-plugins` followed by `sudo install -m 0755 /usr/lib/cni/* /opt/cni/bin/`; kubelet then retries pod sandbox creation.

Do not run an unpinned `curl | sh` installer as the final repeatable setup procedure. When component choices are finalized, record official source URLs, checksums/signatures where supplied, and exact commands here.