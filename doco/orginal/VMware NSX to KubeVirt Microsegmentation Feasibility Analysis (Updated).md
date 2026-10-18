# VMware NSX to KubeVirt Microsegmentation Feasibility Analysis

## 1\. Overview & Strategy

This document details a uniform, port-focused microsegmentation firewall rule hierarchy across VMware NSX and Kubernetes/OpenShift (KubeVirt). The strategy relies strictly on Layer 3/Layer 4 traffic isolation and a default-deny security posture without the overhead or complexity of Layer 7 payload inspection.

---

## 2\. Rule Hierarchy & Prioritization Mapping

### Tier 1: Emergency & Platform Level Rules

- **VMware NSX:** Implemented in NSX DFW under Categories **Emergency** and **Infrastructure** (evaluated top-to-bottom before lower categories).  
- **Kubernetes / OpenShift:** Enforced via Clusterwide Policies (e.g., `CiliumClusterwideNetworkPolicy` or administrative system namespaces).  
- **Traffic Scope:**  
  - Explicitly permits core platform infrastructure traffic:  
    - DNS (UDP/TCP 53\)  
    - Kubelet / Kubernetes API (TCP 6443\)  
    - CNI Overlay (UDP 8472 VXLAN / UDP 6081 Geneve)  
    - Host Management & SSH (TCP 22\)  
  - Enforces top-level emergency blocks and quarantine actions across all workloads.

### Tier 2: Group & Environment Level Rules

- **VMware NSX:** Implemented under Category **Environment** (e.g., isolating `production` from `staging`/`development` or restricting access to management subnets).  
- **Kubernetes / OpenShift:** Enforced via Namespace-level baseline `NetworkPolicy` objects.  
- **Traffic Scope:**  
  - Establishes a global **Default-Deny Ingress and Egress** baseline (`spec: podSelector: {}`).  
  - Restricts cross-namespace / cross-environment traffic unless explicitly whitelisted at the namespace boundary.

### Tier 3: Application & Workload Level Rules

- **VMware NSX:** Implemented under Category **Application** using dynamic NSX Security Groups driven by VM Tags (`tier=web`, `tier=db`, `app=payroll`).  
- **Kubernetes / OpenShift:** Enforced via standard `NetworkPolicy` resources selecting Pods and KubeVirt `VirtualMachineInstance` workloads via Kubernetes Labels (`app: web`, `app: db`).  
- **Traffic Scope:**  
  - Granular port-level rules (e.g., allow TCP 5432 from `app=web` to `app=db`).

---

## 3\. Consistent Infrastructure as Code (IaC) Framework

To achieve identical firewall rule structures across platforms, rules are defined in a vendor-neutral YAML schema and compiled via Terraform or Ansible into platform-native API calls.

### Declarative Security Policy Schema (YAML)

security\_policy:

  name: payroll-app-isolation

  environment: production

  default\_action: deny\_all

  rules:

    \- name: allow-web-to-db

      protocol: TCP

      destination\_port: 5432

      source:

        tag\_or\_label: tier=web

      destination:

        tag\_or\_label: tier=db

    \- name: allow-mgmt-ssh

      protocol: TCP

      destination\_port: 22

      source:

        cidr: 192.168.1.0/24

      destination:

        tag\_or\_label: env=production

### IaC Mapping Engine

- **VMware NSX:** Terraform (`vmware/nsxt` provider) maps the schema to `nsxt_policy_security_policy` and `nsxt_policy_group` resources.  
- **Kubernetes / OpenShift:** Terraform (`hashicorp/kubernetes` provider) or Ansible (`kubernetes.core`) maps the schema to `kubernetes_network_policy` resources targeting KubeVirt VM pods.

---

## 4\. KubeVirt Interface & Network Policy Considerations

- **Binding Modes:** KubeVirt Virtual Machines must use `masquerade` or `bridge` (with CNI support) binding modes to ensure tap interfaces attach cleanly to the pod network namespace where `NetworkPolicy` filtering is executed.  
- **Enforcement Uniformity:** By standardizing on L3/L4 port definitions, both NSX DFW vNIC filters and Kubernetes CNI iptables/eBPF filters enforce identical default-deny and explicit allow rules without configuration drift.