# **VMware NSX to Red Hat OpenShift Microsegmentation Migration Implementation Diagrams**

> Historical diagrams of a proposed migration, not implemented pipelines or current procedures. See the [current design](../HIGH-LEVEL-DESIGN.md), [checkpoint](../IMPLEMENTATION-STATUS.md), and [archive notes](README.md).

## **1\. Implementation Sequence Diagram**

Detailed execution sequence covering dual-policy staging, workload cutover, validation, and legacy decommissioning.  
```mermaid
sequenceDiagram
    autonumber
    actor Admin as Platform Engineer
    participant Git as Git Repository (Policy Source)
    participant CI as CI/CD Policy Compiler Pipeline
    participant NSX as VMware NSX Manager API
    participant MTV as Migration Toolkit for Virtualization
    participant OCP as OpenShift Cluster (Argo CD / OVN-Kubernetes)

    Admin->>Git: Commit policy change and VM migration manifest
    Git->>CI: Trigger validation pipeline
    rect rgb(230, 240, 255)
        note over CI,NSX: Phase 1: Stage and validate both policy sets
        CI->>CI: Compile platform-specific policy artifacts
        CI->>NSX: Apply NSX policy through Terraform
        NSX-->>CI: Confirm NSX policy status
        CI->>OCP: Reconcile network policy through GitOps
        OCP-->>CI: Confirm cluster policy status
    end
    rect rgb(255, 245, 230)
        note over MTV,OCP: Phase 2: Migrate workload and cut over
        Admin->>MTV: Start VM migration
        MTV->>NSX: Detach or shut down source workload
        MTV->>OCP: Create KubeVirt VM with approved labels and network settings
        OCP->>OCP: Verify workload is attached to the intended policy path
    end
    rect rgb(230, 255, 230)
        note over OCP,NSX: Phase 3: Validate traffic and retire legacy policy
        OCP->>OCP: Test allowed and denied flows
        Admin->>NSX: Remove legacy policy only after approval
        NSX-->>Admin: Confirm removal
    end
```

## **2\. Unified Object & Entity Relationship Diagram**

Mapping of declarative source policy entities to target platform resources across VMware NSX and Red Hat OpenShift.  
```mermaid
classDiagram
    class DeclarativePolicySpec {
        +String schemaVersion
        +String policyName
        +String environment
        +String defaultAction
        +List~RuleSpec~ rules
    }
    class RuleSpec {
        +String name
        +Int priority
        +String category
        +String protocol
        +Int destinationPort
        +Map matchLabels
        +String action
    }
    class NsxSecurityPolicy {
        +String display_name
        +String category
        +Boolean stateful
        +List~NsxRule~ rules
    }
    class NsxSecurityGroup {
        +String display_name
        +String criteria_tag
    }
    class OpenShiftAdminNetworkPolicy {
        +String name
        +Int priority
        +NamespaceSelector namespaceSelector
        +List~IngressRule~ ingress
        +List~EgressRule~ egress
    }
    class KubeVirtVMI {
        +String name
        +Map labels
        +String bindingMode
    }

    DeclarativePolicySpec "1" *-- "1..*" RuleSpec
    DeclarativePolicySpec ..> NsxSecurityPolicy : Compiles to
    DeclarativePolicySpec ..> OpenShiftAdminNetworkPolicy : Compiles to
    NsxSecurityPolicy "1" o-- "1..*" NsxSecurityGroup : Uses groups
    OpenShiftAdminNetworkPolicy "1" --> "1..*" KubeVirtVMI : Selects workloads
```
