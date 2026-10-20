# Validate Azure and NSX Targets

Return to the [project README](../../README.md) or the [three-platform architecture](../../doco/ARCHITECTURE.md). This task covers static and plan validation; runtime verification requires access to the corresponding platform.

## Steps

**Status: planned validation checklist.** This directory does not yet contain a runnable adapter, Terraform module, or validation script. The steps below describe gates for future implementation, not commands to execute against the current lab.

1. Confirm the shared policy intent and platform capability checks pass before generating any provider-specific resources.
2. For Azure, validate the intended VNet address space, subnets, NSG association scope, rule priorities, and built-in default rules. NSGs attach to a subnet or NIC, not directly to a VNet.
3. Run formatting and static validation with the pinned Terraform/AzureRM provider versions. Review the plan for replacements, broad ingress/egress, and resources that could incur charges.
4. Do not apply Azure resources until the subscription, region, budget alert, least-privilege permissions, and remote state location are approved.
5. For NSX, validate configuration with the pinned NSX provider. Do not apply without licensed NSX Manager access, approved credentials, state, and a reviewed plan.
6. Static validation and provider plans are not enforcement proof. Where access exists, inspect effective platform policy and run matching positive and negative flow tests.
7. Record unsupported mappings and platform-specific differences with the policy revision. Never silently omit a rule that a backend cannot represent.