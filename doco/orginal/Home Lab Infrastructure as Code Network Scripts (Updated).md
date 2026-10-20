# **Home Lab Infrastructure as Code Network Scripts**

> Historical proposal, not implemented modules. The escaped/incomplete examples below are not executable project files. Use the [current architecture](../ARCHITECTURE.md), [task guides](../../scripts/README.md), and [archive notes](README.md).

Declarative network isolation and firewall management architecture using Terraform, VMware NSX, and Kubernetes NetworkPolicies.

---

# **1\. Project Directory Architecture**

The following file layout standardizes the separation of environmental root calls from modular network components across NSX and Kubernetes domains.terraform-homelab/

├── main.tf                 \# Primary entrypoint combining module invocations

├── variables.tf            \# Global variable declarations

├── outputs.tf              \# Module output declarations

├── terraform.tfvars        \# Environment-specific configuration values

├── providers.tf            \# Provider blocks and version locks

└── modules/

    ├── nsx\_network/        \# VMware NSX Distributed Firewall & Segment modules

    │   ├── main.tf

    │   ├── variables.tf

    │   └── outputs.tf

    └── k8s\_isolation/     \# Kubernetes NetworkPolicy & KubeVirt network modules

        ├── main.tf

        ├── variables.tf

        └── outputs.tf

## **Module Responsibilities**

| Directory / Module | Description | Core Dependencies |
| :---- | :---- | :---- |
| `root` | Coordinates state, provider configurations, and module instantiation | Terraform \>= 1.5.0 |
| `modules/nsx_network` | Provisions VMware NSX security groups, DFW rules, and micro-segmentation | `vmware/nsxt` provider |
| `modules/k8s_isolation` | Manages namespace-level ingress/egress policies for container workloads | `hashicorp/kubernetes` provider |

---

# **2\. Provider Configurations (`providers.tf`)**

This file manages provider initializations, pinning specific version constraints to maintain API stability across deployments.l  
terraform {  
required\_version \= "\>= 1.5.0"  
required\_providers {  
nsxt \= {  
source  \= "vmware/nsxt"  
version \= "\~\> 3.4.0"  
}  
kubernetes \= {  
source  \= "hashicorp/kubernetes"  
version \= "\~\> 2.23.0"  
}  
}  
}

provider "nsxt" {  
host                 \= var.nsx\_manager\_host  
username             \= var.nsx\_username  
password             \= var.nsx\_password  
allow\_unverified\_ssl \= true  
}

provider "kubernetes" {  
config\_path    \= "\~/.kube/config"  
config\_context \= "default"  
}

\---

\#\# 3\. VMware NSX Distributed Firewall & Isolation Module (\`modules/nsx\_network/main.tf\`)

Defines network groupings based on dynamic VM tags and establishes Distributed Firewall (DFW) rules to isolate workloads and control lateral movement.

\`\`\`hcl

resource "nsxt\_policy\_security\_policy" "isolation\_policy" {

  display\_name \= "HomeLab-Network-Isolation"

  description  \= "Distributed Firewall rules isolating K3s infrastructure and virtual machines"

  category     \= "Application"

  locked       \= false

  stateful     \= true

  rule {

    display\_name       \= "Allow-Internal-K3s-Traffic"

    source\_groups      \= \[nsxt\_policy\_group.k3s\_nodes.path\]

    destination\_groups \= \[nsxt\_policy\_group.k3s\_nodes.path\]

    action             \= "ALLOW"

    logged             \= true

  }

  rule {

    display\_name       \= "Block-Cross-Segment-Egress"

    source\_groups      \= \[nsxt\_policy\_group.isolated\_vms.path\]

    destination\_groups \= \[nsxt\_policy\_group.management\_subnet.path\]

    action             \= "DROP"

    logged             \= true

  }

}

resource "nsxt\_policy\_group" "k3s\_nodes" {

  display\_name \= "K3s-Cluster-Nodes"

  criteria {

    condition {

      key         \= "Tag"

      operator    \= "EQUALS"

      member\_type \= "VirtualMachine"

      value       \= "k3s-node"

    }

  }

}

resource "nsxt\_policy\_group" "isolated\_vms" {

  display\_name \= "Isolated-VM-Workloads"

  criteria {

    condition {

      key         \= "Tag"

      operator    \= "EQUALS"

      member\_type \= "VirtualMachine"

      value       \= "isolated-workload"

    }

  }

}

resource "nsxt\_policy\_group" "management\_subnet" {

  display\_name \= "Management-Subnet"

  cidr         \= "192.168.1.0/24"

}

---

# **4\. Kubernetes NetworkPolicy Isolation Module (`modules/k8s_isolation/main.tf`)**

Configures zero-trust network access control within the Kubernetes cluster, defaulting to an ingress deny-all posture and explicitly permitting required inter-service communication.resource "kubernetes\_network\_policy" "default\_deny\_ingress" {

  metadata {

    name      \= "default-deny-all-ingress"

    namespace \= "kubevirt-workloads"

  }

  spec {

    pod\_selector {}

    policy\_types \= \["Ingress"\]

  }

}

resource "kubernetes\_network\_policy" "allow\_app\_traffic" {

  metadata {

    name      \= "allow-frontend-to-backend"

    namespace \= "kubevirt-workloads"

  }

  spec {

    pod\_selector {

      match\_labels \= {

        app \= "backend-service"

      }

    }

    ingress {

      from {

        pod\_selector {

          match\_labels \= {

            app \= "frontend-service"

          }

        }

      }

      ports {

        protocol \= "TCP"

        port     \= "8080"

      }

    }

    policy\_types \= \["Ingress"\]

  }

}  
