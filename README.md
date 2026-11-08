# KVM Microsegmentation Lab

This project plans and validates a policy-as-code approach to network microsegmentation across VMware NSX, Kubernetes workloads, and Azure Virtual Networks (VNets) with Network Security Groups (NSGs). The first milestone is a small K3s and KubeVirt proof of concept on the existing QEMU/KVM host. OpenShift Virtualization is the preferred longer-term Kubernetes target. NSX and Azure are separate infrastructure backends driven from shared policy intent, not from identical platform resources.

The project is intended to test how workload identity, default-deny policy, explicitly allowed traffic, policy delivery, and validation can be managed consistently. Kubernetes isolation is the primary runtime proof of concept; NSX and Azure implementations also require provider/static checks and platform-specific validation. The project does not claim that the three policy engines behave identically.

## Project Status

The single-node K3s/OVN-Kubernetes/KubeVirt/CDI lab is deployed. Rocky Linux 10 and the Ubuntu client have verified key-based administration; Ubuntu provisioning is unattended and JSON-configured. A separate Rocky 9 desktop provides Firefox and tunneled RDP, and task 45 provides optional monitoring dashboards. Windows installation and isolation testing remain pending. Azure and NSX adapters are planned, not deployed or runtime-verified.

For the current implementation checkpoint, see [Implementation status](doco/IMPLEMENTATION-STATUS.md).

## Before Running Scripts

Do not clean or reset the lab before routine runs. The task scripts are designed to inspect and resume project-owned resources; use the progress checker and follow its `NEXT:` recommendation. A full reset is a separate destructive action: [`cleanup-lab.sh`](scripts/90-cleanup/README.md) permanently deletes the outer VM disk, cluster, and all nested guest disks. Use it only when intentionally rebuilding from task 10, after backing up anything you need.

## Resume After an Interruption

After a power loss, laptop restart, or break, run the one-command resumer from the repository root on the QEMU/KVM host:

```sh
bash scripts/resume-lab.sh                                   # checks only; prompts before starting the outer VM
bash scripts/resume-lab.sh --start-vm --start-fleet --start-desktop   # full restart of VM, fleet guests, and desktop
```

It starts the outer VM (with approval), waits for SSH, runs the cluster health check with the guarded OVN route repair, waits out any pod crash-loop recovery, prints the VM inventory with access methods, optionally reconciles fleet VMs and starts the desktop, and ends with the dashboard-tunnel and access commands. Afterward, reopen the dashboard tunnels and generate a fresh Headlamp token per [Dashboard Quick Access](#dashboard-quick-access) — tunnels and tokens never survive a restart. The microsegmentation next steps are in the [implementation status checkpoint](doco/IMPLEMENTATION-STATUS.md). For deeper diagnosis:

1. Read the checkpoint in [doco/IMPLEMENTATION-STATUS.md](doco/IMPLEMENTATION-STATUS.md) for completed tasks, known blockers, and the resume order.
2. Run the progress checker. It checks the host, outer VM, SSH, guest disk, cluster health, staged media, and task 30 resources, then prints one `NEXT:` recommendation:

   ```sh
   bash scripts/check-lab-progress.sh
   ```

   If the managed outer VM is powered off, the checker asks permission to start it, then waits for networking and SSH. It does not start nested guests. Exit code `0` means the inventory completed, not that every deployment stage passed; read the `WARN`, `BLOCKED`, and `NEXT:` lines.

3. Follow the `NEXT:` step. The task guides in [scripts/README.md](scripts/README.md) cover troubleshooting and resizing the outer VM disk.
4. Update the checkpoint file when a task completes or a new blocker is found.

The task scripts preserve partial state and resume project-owned resources. Do not delete the `netpol-test` namespace or run cleanup to "start fresh" unless the checker or checkpoint says to.

## Restart Test VMs and Verify Microsegmentation

From the repository root on the physical QEMU/KVM host, resume the outer VM and check the lab state:

```sh
bash scripts/check-lab-progress.sh
bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh
```

The progress checker prompts before starting the outer VM if it is powered off. Once the cluster is healthy, start the installed test guests as needed:

```sh
export KUBECONFIG="$PWD/work/kubeconfig-lab-k8s-01.yaml"
work/virtctl-v1.9.1 start netpol-server-rocky -n netpol-test
work/virtctl-v1.9.1 start netpol-client -n netpol-test
```

Keep `netpol-server-windows` powered off during the Rocky test; test Windows separately by starting it instead of Rocky. The guest start commands only start existing VMs and preserve their disks. Follow the [task 35 isolation test procedure](scripts/35-verify-kubernetes-isolation/README.md) to apply policies and verify allowed and denied connections. It is currently a manual test procedure, not an automated runner. **Do not run** `run-isolation-test.sh` for the installed task 30 guests: that legacy script creates its own namespace and VMs. See the [task 30 guide](scripts/30-create-kubevirt-vms/README.md) for guest setup and stop/start details.

## Dashboard Quick Access

With the two tunnel helpers running (`bash scripts/45-monitoring-dashboard/access-dashboards.sh --host` and `bash lab-switchboard/scripts/access.sh`), open:

| Dashboard | URL | Login |
| --- | --- | --- |
| Lab Switchboard (VM control portal) | <http://localhost:18088> | password in `lab-switchboard/.local/admin-password` |
| Headlamp (Kubernetes) | <http://localhost:18080> | short-lived token in `work/headlamp-token`; regenerate with `bash scripts/45-monitoring-dashboard/dashboard-permissions.sh token` |
| Cockpit (outer `lab-k8s-01` VM OS) | <https://localhost:19090> | `cockpit-monitor` + password in `work/cockpit-monitor-password` |
| Cockpit on a fleet VM (per-VM OS view) | printed by `bash scripts/34-vm-fleet/setup-vm-fleet.sh --cockpit <name>` | `labadmin` + password set with `--set-password <name>` |

Tunnels are terminal/background processes, not boot services: reopen them after a reboot. Credential files are Git-ignored and never printed; read them privately. Details and troubleshooting: [monitoring inventory](doco/MONITORING.md), [dashboard runbook](scripts/45-monitoring-dashboard/README.md), and the [Switchboard guide](lab-switchboard/README.md).

## Documentation

- [Lab Switchboard: containerized VM control and dashboard portal](lab-switchboard/README.md)
- [Monitoring tools and dashboards: inventory and where each is accessed](doco/MONITORING.md)
- [Install and open the monitoring dashboards (Cockpit and Headlamp)](scripts/45-monitoring-dashboard/README.md)
- [VM access: list running VMs/protocols, SSH, and RDP](scripts/README.md#vm-access-ssh-and-rdp)
- [Start or resume the lab: task guides](scripts/README.md)
- [Documentation index](doco/README.md)
- [Implementation status and resume checkpoint](doco/IMPLEMENTATION-STATUS.md)
- [Architecture](doco/ARCHITECTURE.md)
- [High-level design](doco/HIGH-LEVEL-DESIGN.md)
- [Lab setup and prerequisites](doco/LAB-SETUP.md)
- [Configuration, operation, and maintenance guide](doco/OPERATIONS-GUIDE.md)
- [Project plan and open decisions](doco/PROJECT-PLAN.md)
- [Task-by-task setup guides and scripts](scripts/README.md)
- [Original source material](doco/orginal/)

## Intended Delivery Model

- A version-controlled policy definition is the shared source of intent, with platform-specific validation and outputs.
- Argo CD is the proposed reconciler for Kubernetes resources.
- Terraform with separate provider configurations and state manages Azure VNets/NSGs and NSX resources; NSX requires a supported, licensed, reachable environment.
- A policy compiler/adapter must reject unsupported semantics rather than silently weakening a policy. Exact cross-platform equivalence is not assumed.

## Current Constraints

- The host is QEMU/KVM-based and there is no VMware license, so NSX resources cannot currently be deployed or runtime-validated.
- Azure deployment requires an Azure subscription, permissions, cost controls, and a selected region; these are not yet confirmed.
- Upstream OVN-Kubernetes is installed and its pinned configuration has passed lab checks. This is not proof of OpenShift dataplane parity or network-policy enforcement; isolation tests are still pending. Flannel is a design fallback, not the deployed CNI.
- Disk capacity currently exceeds the lab planning target; monitor free space as VM images and snapshots grow.
- Local component versions and task-specific configuration are recorded in the task guides. Cross-platform policy contracts, cloud access, and production acceptance criteria still require decisions. Design proposals are not deployment instructions.

## Scope

The initial scope is a single-node, disposable K3s/KubeVirt lab that demonstrates policy behavior, Git-based changes, and repeatable validation across Ubuntu, a RHEL-compatible Rocky Linux guest, and a Windows Server evaluation guest. The design includes independently generated NSX, Kubernetes, and Azure targets. High availability, production operations, migration tooling, and claims of behaviorally identical enforcement are out of scope.

## Lab VM Plan

Use one outer QEMU/KVM guest for K3s and KubeVirt, then an Ubuntu client, Rocky Linux server, and Windows Server evaluation guest inside KubeVirt for isolation tests. The Rocky desktop is a standard lab guest but separate from this test matrix. See the [lab setup guide](doco/LAB-SETUP.md) and the [setup task guides](scripts/README.md). Do not create separate K3s control-plane and worker VMs for the initial proof of concept.