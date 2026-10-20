# Pause and Resume Checkpoint

Recorded: **2026-10-21**. Work is paused at the user's request after implementation, deployment, and verification. This is dated evidence, not a guarantee of future live state.

**PC shutdown planned:** assume all lab services, VMs, browser sessions, and SSH/RDP/VNC connections may be stopped when work resumes. The observations below were taken before shutdown. Do not assume that a saved browser tab or a previously active localhost URL means the service is running. Follow [Resume After PC Shutdown](#resume-after-pc-shutdown) before testing or developing.

## Where We Stopped

All four implementation tasks are complete:

| Task | Status |
| --- | --- |
| Authenticated VM control API | Complete |
| Portal interface and guest access commands | Complete |
| Container packaging and K3s deployment | Complete |
| Documentation and end-to-end verification | Complete |

No further implementation step is in progress. The next session should verify the existing deployment and review the user experience before selecting additional work. Do not rebuild the lab or reinstall guest operating systems to resume this project.

## Deployment and Access

- Project: this `lab-switchboard/` directory within the parent IaC repository.
- Deployment: `deployment/lab-switchboard` and ClusterIP `service/lab-switchboard` in namespace `lab-switchboard`.
- Image: `docker.io/library/lab-switchboard:0.1.0`, built with Podman in the managed outer Ubuntu VM and imported into K3s containerd. The Node base image is digest-pinned in [Containerfile](Containerfile).
- Runtime: single non-root replica, read-only root filesystem, restricted security context, no host mounts or private SSH keys.
- Portal login: separate random password in ignored `.local/admin-password`, with directory mode `0700` and file mode `0600`. Never paste its contents into chat or logs.
- Laptop access: SSH helpers, not ingress, NodePort, or a LAN-wide listener.

| Endpoint | Observation at Pause |
| --- | --- |
| <http://localhost:18088> | Portal loopback listener active; `/healthz` returned `{"healthy":true}` |
| <http://localhost:18080> | Headlamp loopback listener active |
| <https://localhost:19090> | Cockpit loopback listener active |

The deployment and both SSH tunnel helpers were running when inspected, **before the planned PC shutdown**. No shutdown was performed by the assistant. After the PC shuts down, assume those processes and connections are gone. The outer VM may need starting; K3s, Cockpit, and the portal pod may need recovery; nested guest VMs may remain stopped. SSH tunnels are terminal processes, not persistent boot services, and must be reopened after reboot. Local listeners alone do not prove dashboard login works.

Before shutting down the PC, finish or safely pause any ongoing guest installation/disk writes and gracefully shut down nested guests and then the outer VM. Do not force-stop a Windows installation merely to match this checkpoint. This note does not initiate shutdown or verify that guests have finished shutting down.

## Verified Before Pause

- Three offline tests passed: KubeVirt response negotiation, VM-control guards, and HTTP login/session/CSRF/confirmation behavior.
- `npm audit --audit-level=moderate` reported zero known npm vulnerabilities.
- Deployed pod readiness, ClusterIP service type, and scoped allow/deny RBAC checks passed.
- The authenticated live smoke test returned four real VM resources and checked assets, invalid-request rejection, namespace boundaries, and logout.
- Both complete start/stop paths passed against real KubeVirt with explicit `dryRun: ["All"]`. No guest was started or stopped by those checks. Actual guest power-cycle testing was intentionally not performed.
- Desktop (1440px) and mobile (390px) demo-browser checks passed, including screenshots, loaded assets, no horizontal overflow, guest access commands, simulated start/stop, and confirmation/cancel.
- Script syntax, edited documentation links/fences, whitespace, and editor diagnostics passed.
- The final deployed login page was opened in the integrated browser. Authenticated live API checks read the credential internally without exposing it; UI action tests used simulated guests rather than the running Windows installation.

## Resume After PC Shutdown

Run these commands from the **parent repository root on the physical KVM-host laptop**, not inside a guest:

1. Boot the PC, open a fresh terminal in the repository, and run the existing lab inventory/recovery entry point:

   ```sh
   bash scripts/check-lab-progress.sh
   ```

   If the managed outer VM is stopped, this helper asks permission to start it. Approve only when ready, then allow time for guest networking, SSH, and the cluster to recover. Read its warnings and `NEXT:` recommendation; exit zero does not mean every workload is healthy. It does not automatically start the nested guest VMs. Do not rerun provisioning or recreate disks.

2. Check cluster readiness and configuration:

   ```sh
   bash scripts/20-install-k3s-kubevirt/check-cluster-status.sh
   ```

   The known OVN guest-network repair is runtime-only and may be needed after reboot; use the [task 20 diagnostics](../scripts/20-install-k3s-kubevirt/README.md#check-progress-and-troubleshoot) if SSH/networking fails. If the outer VM is reachable but K3s or Cockpit is not active, log in with `bash scripts/10-create-lab-vm/login-lab-vm.sh`, inspect `sudo systemctl status k3s cockpit.socket`, and start a stopped required service with `sudo systemctl start k3s` or `sudo systemctl start cockpit.socket`. Inspect failures rather than reinstalling. Exit the guest shell before continuing host commands.

3. Verify the existing portal deployment without rebuilding or changing guest state:

   ```sh
   bash lab-switchboard/scripts/deploy.sh --verify
   ```

   Kubernetes should reconcile the saved portal Deployment once the node is Ready; this is an expectation, not a guaranteed restart result. If the pod is unhealthy, inspect its events/logs and image availability. The locally imported container image and saved credentials should persist on the outer VM disk. Do not rebuild or regenerate passwords just because a tunnel is missing.

4. Reopen the portal SSH tunnel in a host terminal and leave it running:

   ```sh
   bash lab-switchboard/scripts/access.sh
   ```

5. Reopen the Headlamp/Cockpit tunnel in a **second host terminal** and leave it running:

   ```sh
   bash scripts/45-monitoring-dashboard/access-dashboards.sh --host
   ```

   If either helper reports an occupied port, identify any already-restarted helper before starting another. Saved terminals do not automatically recreate a working SSH connection.

6. In a third terminal, verify authenticated live reads and guards, without changing VM state:

   ```sh
   node lab-switchboard/scripts/smoke-test.mjs
   ```

7. Open <http://localhost:18088>, obtain the portal password privately from the existing local file, and sign in again. In-memory portal sessions do not survive a server restart. Headlamp may need a fresh token; Cockpit needs its own OS login. Review the live inventory and main lab checkpoint before starting only the nested guests required for the next task. Guests use Manual runStrategy; do not assume they restart automatically. Start one at a time as capacity and installation state permit, then reopen SSH/VNC/RDP using the displayed commands. Previous desktop and terminal connections will not survive the PC shutdown.

If SSH or the cluster is unavailable, follow the parent repository's existing lab recovery procedures first. Do not rerun provisioning/creator scripts for installed guests. Start/stop controls can interrupt ongoing Windows setup or disk maintenance; review the main lab checkpoint and current activity before using them.

## Development and Redeployment

To resume code changes:

```sh
npm --prefix lab-switchboard ci
npm --prefix lab-switchboard test
npm --prefix lab-switchboard audit --audit-level=moderate
```

For a local simulated UI, from this project directory use `PORT=18089 npm run dev`; the demo server used for verification was stopped and will not restart automatically. The deployed portal also requires the post-shutdown recovery and tunnel steps above before it is reachable. Demo mode uses the public development password documented in [README.md](README.md) and never changes real VM state.

Only after intentional code/configuration changes, rebuild and redeploy:

```sh
bash lab-switchboard/scripts/deploy.sh --apply
```

Podman is already installed in the outer VM; do not repeat builder installation unless rebuilding that VM. Deployment reuses the local password, imports the image, and restarts the portal, which invalidates sessions and the old port-forward. Reopen the access helper afterward. Detailed output from the last build is in ignored `.local/deploy.log`.

## Important Implementation Notes

- KubeVirt lifecycle endpoints return empty HTTP 202 replies and reject a JSON-only `Accept` header with HTTP 406. The client uses `Accept: */*`; keep the transport regression test.
- KubeVirt start/stop authorization verification uses explicit `SelfSubjectAccessReview` requests. Its subresource discovery does not work with the naive `kubectl auth can-i` form. `--validate=false` avoids client-side CRD-listing under the restricted impersonated account; the API server still validates the review.
- Keep `npm test` scoped to `test/*.test.js`; default Node discovery also finds the optional live smoke test and unexpectedly requires running services/credentials.
- Rocky desktop RDP uses the existing `setup-rocky-desktop.sh --rdp` SSH helper because xrdp is guest-loopback-only. Windows RDP commands still depend on completed installation and guest service/firewall/port configuration.
- Outer libvirt VM start/shutdown remains a copied host command, not a browser API action. Headlamp RBAC, Cockpit sudo, and portal VM-control permissions are independent.
- This project remains a single-user lab application: shared password, in-memory sessions, single-node local image import, no embedded browser console, no public ingress, and no remote registry/repository publication. See [SECURITY.md](SECURITY.md).

## Git and Remaining Decisions

At pause, `git status --short -- lab-switchboard` reported `?? lab-switchboard/`: the project has **not been staged or committed**. No Git commit or branch was created. The parent worktree also contains existing user/other-task changes; preserve them and review/stage deliberately.

Dependencies, local credentials, build/test output, environment files, and logs are excluded by the root/project ignore rules; the container context also excludes private local files. Keep the dependency lockfile, source/configuration, manifests, documentation, license, and intended screenshot assets under version control.

There is no known blocking implementation defect at pause. Future decisions include deliberate real-guest lifecycle acceptance testing at a safe time, public repository/maintainer/security-report ownership, and any production features such as OIDC, persistent sessions, TLS, NetworkPolicy, registry distribution, or multi-user authorization. None of those were implemented or approved as part of the completed lab scope.

For full usage and operational detail, start with [README.md](README.md), [SECURITY.md](SECURITY.md), and [CONTRIBUTING.md](CONTRIBUTING.md).