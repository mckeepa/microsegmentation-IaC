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

This permanently deletes the outer VM disk and everything inside it: the cluster, all nested VM disks (including the optional desktop), and installed dashboards. It removes the outer VM's generated SSH key, known-hosts file, seed ISO, and exported kubeconfig. The script verifies the libvirt ownership marker and disk path, requests a graceful shutdown, and refuses to force-stop the VM if shutdown times out. Downloaded Ubuntu, Rocky, and Windows ISOs are retained. Other generated guest keys, dashboard credential files, and image caches may remain under ignored `work/`; review them separately rather than assuming full credential erasure. Unrelated host VMs, networks, and storage volumes are not deleted.

After cleanup, rerun task 10 to recreate the outer VM, then task 20 to bootstrap the cluster. Task 20 also invokes task 10 automatically when the managed VM is absent.

## Before a Full Reset

1. Export required results and back up any useful guest data. Keep secrets and kubeconfig credentials out of Git; review manifests before committing them.
2. Close RDP, dashboard, and SSH tunnels and gracefully stop guest workloads.
3. Preview `cleanup-lab.sh --dry-run` and confirm the managed VM and disk are the intended targets.
4. Run the guarded `--execute` command above. Do not replace this with manual deletion in Virtual Machine Manager.
5. Recheck host free space with the [preflight script](../00-host-preflight/check-host.sh), then record the reset in the checkpoint.

For partial cleanup, inspect ownership and dependencies first and remove only the intended resources. Deleting a Kubernetes namespace or PVC can destroy installed guests; the full-reset script is not a partial-cleanup tool. Argo CD is not currently installed, so do not assume it will restore deleted lab resources.