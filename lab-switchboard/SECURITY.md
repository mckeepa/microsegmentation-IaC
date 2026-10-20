# Security Policy

## Intended Deployment

Lab Switchboard 0.1.x is intended for a trusted, single-user, disposable home lab behind SSH tunnels. Do not expose it directly to the internet. No public security-report inbox or remote repository is configured here. Before publishing this project, establish a private reporting channel; do not post credentials, kubeconfigs, guest user-data, or exploit details in a public issue.

## Privilege Boundary

- The service account can get/list VM and VMI resources and update only VM start/stop subresources in two named namespaces. It cannot read Kubernetes Secrets, exec into pods, patch VM definitions, or access libvirt.
- Ownership and Manual runStrategy checks are application-level guards. Kubernetes RBAC does not enforce the ownership label. A compromised portal/token could start or stop any VM in its authorized namespaces, regardless of labels. For stronger isolation, use dedicated namespaces or RBAC `resourceNames` for fixed guests, and review effective grants.
- Guest VM definitions can include sensitive cloud-init information. The service account must read VM definitions to check ownership; the browser receives only reduced inventory. Do not place secret material directly in labels, ConfigMaps, or configuration.
- Portal login grants the same VM-control capabilities to every holder. There is no per-user identity, read-only role, MFA, or OIDC integration in this version. Headlamp's read-only/admin toggle is independent of the portal.
- No host private keys, administrator kubeconfig, container socket, or host filesystem are mounted into the pod. Host command snippets are copied, not executed by the server.

## Authentication and Transport

The app requires a random password of at least 24 characters, delivered through a Kubernetes Secret. The local generated password is plaintext under `.local/` with restrictive file/directory permissions. Kubernetes Secrets are not necessarily encrypted at rest; protect cluster administration, datastore backups, and host access.

Sessions use a signed HttpOnly, SameSite=Strict cookie and an unpredictable CSRF token for state changes. Sessions expire after four hours and are held in memory, suitable only for the one-replica lab deployment. A restart logs everyone out. Do not scale replicas or use this session store for a multi-user/public service; add a bounded shared session store and identity provider first. Login attempts and VM actions are rate limited per direct client IP. Port-forward access may share an apparent source IP and therefore share a rate-limit bucket.

HTTP is allowed only because the documented remote path is protected by SSH and endpoints are loopback-only. A ClusterIP service can still be reached by other cluster workloads. This version does not install network policies or backend TLS. If those workloads are untrusted, add reviewed NetworkPolicy and TLS termination before use. HTTPS ingress deployments require secure cookies (`COOKIE_SECURE=true`), trusted-proxy configuration if applicable, reviewed origin behavior, and independent security validation.

## VM Actions

Start/stop requests are confirmed in the UI, validated on the server, and recorded without credentials. Shutdown is graceful, not guaranteed; the guest can remain active or lose unsaved work. There is no force-stop endpoint. Concurrent starts can exhaust capacity. Requests can race with external administrators changing VM state/labels between validation and execution; the platform's own authorization and conflict responses still apply. Do not treat the portal as an approval system or full resource scheduler.

## Secrets and Reports

Never attach `.local/`, `.env*`, parent `work/`, passwords, service-account tokens, private keys, or live kubeconfigs to a report. They are excluded from the Git/build context by the supplied rules, but ignore rules do not erase already committed files or protect plaintext backups. Rotate credentials exposed in chat/logs and restart relevant sessions. Review screenshots before publishing them.

Keep the npm lockfile, audited dependencies, base-image digest, K3s, and KubeVirt versions under review. `npm audit` covers known npm advisories only, not operating-system/container vulnerabilities or application authorization correctness. Before any production or public deployment, perform image scanning and a broader security review.