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

The historical 2026-10-18 host snapshot recorded 16 logical CPUs, 62 GiB total RAM, nested Intel virtualization, KVM device access, and 461 GiB free on the root filesystem. Available RAM/free disk change as guests run; only the live report determines whether thresholds pass now.

The available-memory threshold is **physical-host `MemAvailable` before provisioning**, not the outer VM's free RAM. A running lab consumes host memory, so this check can fail later even though its existing guests are running. Increasing the outer VM's memory does not fix that host threshold. Close unneeded host workloads and review live capacity before allocating more RAM.

To inspect host/VM memory and interactively change the outer VM's **next-boot** allocation, use the [guarded memory-sizing helper](../10-create-lab-vm/README.md#change-the-vm-memory). It prompts for total GiB and confirmation, checks host headroom, and does not restart the lab.