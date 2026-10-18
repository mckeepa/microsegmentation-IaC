# Host Preflight

Return to the [project README](../../README.md) or review the [lab requirements](../../doco/LAB-SETUP.md). This task checks that the current Linux host can support the planned outer lab VM. It makes no system changes.

## Steps

1. Open a terminal at the project root.
2. Run the read-only check:

   ```sh
   bash scripts/00-host-preflight/check-host.sh
   ```

3. Confirm the report shows at least 8 logical CPUs, 32 GiB available memory, 150 GiB free on `/`, nested virtualization enabled, and readable/writable `/dev/kvm`.
4. If a check fails, resolve the host prerequisite or reduce the proposed VM allocation and update the lab plan before proceeding. Do not work around `/dev/kvm` permissions with broad device permissions.
5. Re-run this check immediately before creating the guest because memory and disk usage change over time.

The current recorded host snapshot passed these planning thresholds: 16 logical CPUs, 62 GiB RAM, nested Intel virtualization enabled, KVM device access confirmed, and 461 GiB free on the root filesystem. This script reports live values and does not rely on that earlier snapshot.