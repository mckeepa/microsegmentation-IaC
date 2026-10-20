# Documentation

These documents describe the intended KVM-hosted proof of concept and its path toward an OpenShift Virtualization design. Items marked **TBD** require confirmation or testing before they can be treated as implementation instructions.

## Start Here

For commands, start with the [implementation checkpoint](IMPLEMENTATION-STATUS.md) and [task guides](../scripts/README.md). For a new lab, follow the task order; for an existing lab, do not repeat provisioning without checking its state. Run host commands from the repository root, not from a nested guest SSH session.

1. [Architecture](ARCHITECTURE.md): system boundaries, responsibilities, and major technical constraints.
2. [High-level design](HIGH-LEVEL-DESIGN.md): the proposed deployment topology and policy workflow.
3. [Lab setup](LAB-SETUP.md): host readiness, prerequisites, and capacity planning.
4. [Operations guide](OPERATIONS-GUIDE.md): the configure, deploy, validate, and maintain workflow.
5. [Project plan](PROJECT-PLAN.md): milestones, completion gates, and open decisions.
6. [Implementation status](IMPLEMENTATION-STATUS.md): durable current checkpoint and safe resume order.
7. [Monitoring and dashboards](MONITORING.md): monitoring inventory, Cockpit/Headlamp setup, secure laptop access, and read-only/admin switching.

The [original source material](orginal/) is retained as reference. It includes exploratory proposals and duplicated or incomplete documents; it is not an authoritative runbook.