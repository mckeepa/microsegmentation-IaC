# Monitoring and Dashboards

## Scope

The physical KVM host runs the outer Ubuntu VM `lab-k8s-01`. That VM runs K3s, OVN-Kubernetes, KubeVirt, and CDI; the Ubuntu/Rocky/Windows test VMs run inside KubeVirt. Keep these monitoring layers distinct.

| Tool | Layer and Purpose | Access / Procedure |
| --- | --- | --- |
| Lab Switchboard | Authenticated VM inventory/start/stop controls, dashboard launchers, and host command desk | [Project setup and security guide](../lab-switchboard/README.md); <http://localhost:18088> after running its access helper |
| Cockpit | Outer Ubuntu VM CPU, RAM, filesystems, network, services, and journal | Optional [task 45 setup and SSH tunnels](../scripts/45-monitoring-dashboard/README.md); <https://localhost:19090> after tunneling |
| Headlamp | K3s nodes, pods, workload status, events, logs, services, PVCs, and Kubernetes resource details | Optional [task 45 setup, tokens, and permission switching](../scripts/45-monitoring-dashboard/README.md); <http://localhost:18080> after tunneling |
| Lab progress checker | Whole-lab inventory, checkpoint, and next recommended step | `bash scripts/check-lab-progress.sh`; [task index](../scripts/README.md#resume-after-an-interruption) |
| Cluster status checker | Node/pod readiness, pinned versions, OVN configuration, KubeVirt, and CDI | `bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh`; [task 20](../scripts/20-install-k3s-kubevirt/README.md) |
| VM lister | Nested VM inventory: running state, cluster-reachable IPs, sizing, labels, forwarded ports, and access methods, with label filters | `bash scripts/list-vms.sh [--running] [-l key=value]`; [VM access guide](../scripts/README.md#vm-access-ssh-and-rdp) |
| Cockpit on fleet VMs | Per-guest OS view (CPU, RAM, services, journal) for task 34 fleet VMs; loopback-only in each guest | `bash scripts/34-vm-fleet/setup-vm-fleet.sh --cockpit <name>`; [fleet guide](../scripts/34-vm-fleet/README.md) |
| libvirt / Virtual Machine Manager | Physical-host resources and the outer `lab-k8s-01` VM | [Task 10](../scripts/10-create-lab-vm/README.md); does not manage nested KubeVirt test VMs |
| `virtctl` console/VNC | Nested guest console, installation, and boot troubleshooting | [Task 30](../scripts/30-create-kubevirt-vms/README.md); depends on guest display/console support, not a web dashboard |
| Ubuntu/Rocky SSH and the Rocky desktop | Interactive guest access, not cluster monitoring; the Ubuntu client is a server image without a desktop | [Ubuntu terminal access](../scripts/30-create-kubevirt-vms/README.md#unattended-ubuntu-setup) and [Rocky desktop runbook](../scripts/32-rocky-desktop/README.md) |
| Isolation test runner | Evidence that guest traffic follows expected allow/deny policies | [Task 35](../scripts/35-verify-kubernetes-isolation/README.md); dashboards alone do not prove enforcement |

Cockpit here monitors the **outer VM**, not the physical host, and does not replace a KubeVirt UI. Headlamp exposes KubeVirt/CDI objects through custom-resource views; a graphical VM lifecycle/console plugin is not installed by this task. Kubernetes resource metrics depend on a healthy metrics API; the dashboards do not install a metrics pipeline.

## Security and Access

For the combined control desk, use [Lab Switchboard](../lab-switchboard/README.md). It is a separate containerized project deployed in K3s, with its own password, CSRF-protected VM controls, and scoped start/stop RBAC. Its VM-control permission is independent of Headlamp's read-only setting. It does not execute host commands or store guest SSH keys. The outer KVM VM is controlled through host command snippets, not the portal API.

Use the [task 45 runbook](../scripts/45-monitoring-dashboard/README.md) for installation, Cockpit password setup, laptop tunnels, login tokens, read-only/admin switching, verification, and removal. Setup defaults to read-only Kubernetes access. Admin mode is explicit and must be switched back manually. Kubernetes access and Cockpit OS permissions are independent.

The libvirt NAT network remains intact. Dashboard listeners are loopback-only or ClusterIP-only; laptop access goes through SSH to the physical host. Do not expose these management interfaces directly to the internet. Keep generated credentials in ignored local storage and never include them in screenshots, Git, or issue reports.

## Routine Checks

1. Use the progress checker after a restart or interruption.
2. Check the node is Ready and core infrastructure pods are healthy before interpreting workload failures.
3. Inspect outer-VM free disk and RAM in Cockpit, and physical-host capacity separately with host tools.
4. Use Headlamp events/logs for failing workloads and PVCs; read-only mode intentionally blocks sensitive or mutating actions.
5. Run isolation tests for policy evidence; a green pod or displayed NetworkPolicy is not proof of enforcement.
6. After dashboard changes, run task 45 `--verify` and check browser login from the laptop.

## Not Installed by This Task

Prometheus, Grafana, Alertmanager, centralized log retention, historical capacity dashboards, alerts, and a full KubeVirt web console are not installed. Cockpit and Headlamp are live operational views, not a durable monitoring/alerting platform. Argo CD and cloud/provider consoles are separate planned integrations, not dashboards supplied by this setup.