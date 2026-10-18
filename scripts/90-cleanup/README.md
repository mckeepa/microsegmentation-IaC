# Clean Up the Lab

Return to the [project README](../../README.md) and review the [maintenance guide](../../doco/OPERATIONS-GUIDE.md) before deleting resources. This lab is disposable; confirm that no useful data is stored in its VM disks.

## Reset the Lab VM

To start again from task 10, preview the cleanup first:

```sh
bash scripts/90-cleanup/cleanup-lab.sh --dry-run
```

To remove the project-managed `lab-k8s-01` VM and its disk, run the script interactively and type the requested confirmation:

```sh
bash scripts/90-cleanup/cleanup-lab.sh --execute
```

This permanently deletes the VM disk and its contents, and removes the generated SSH key, known-hosts file, seed ISO, and exported kubeconfig. The script verifies the libvirt ownership marker and disk path, requests a graceful shutdown, and refuses to force-stop the VM if shutdown times out. Downloaded Ubuntu, Rocky, and Windows ISOs are retained. It does not delete unrelated VMs, networks, or storage volumes.

After cleanup, rerun task 10 to recreate the outer VM, then task 20 to bootstrap the cluster. Task 20 also invokes task 10 automatically when the managed VM is absent.

## Steps

1. Stop test workloads and export any required test results or manifests to the repository.
2. Remove the test VMIs and their disposable disks using the same owner that created them (GitOps or the operator, not both).
3. Remove lab Kubernetes resources in dependency order, preserving notes needed for a reproducible rebuild.
4. Shut down `lab-k8s-01` cleanly from the guest OS.
5. In Virtual Machine Manager, remove the outer VM only after confirming its disk contains no needed data. Do not delete unrelated libvirt VMs or networks.
6. Recheck host free space with the [preflight script](../00-host-preflight/check-host.sh).
7. Record the cleanup date, removed VM disks, and any retained snapshots.