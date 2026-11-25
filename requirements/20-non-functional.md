# Non-Functional Requirements

## NFR-1 Simplicity and discoverability

- **NFR-1.1** One entry point: every operation is a `lab` subcommand; `--help`
  is complete and accurate. No "which script do I run" decisions.
- **NFR-1.2** Repository top level has ≤ 8 folders, each with a one-line purpose
  in the README.
- **NFR-1.3** Documentation lives next to what it documents and never restates
  command behavior that `--help` covers (prevents drift).

## NFR-2 Tooling

- **NFR-2.1** Python (3.12+) is the primary language, packaged as one installable
  project with locked dependencies. Bash only for tiny bootstrap glue (e.g. the
  step that installs Python/uv itself).
- **NFR-2.2** Lint + type-check + unit tests run with one command and pass in CI
  (even if "CI" is just a pre-commit hook initially).
- **NFR-2.3** Pin external versions (K3s, KubeVirt, CDI, CNI and base images)
  in one place, with checksums for downloads. When `latest` selects a built
  image, record its resolved immutable version and checksum for each VM.

## NFR-3 Safety and idempotency

- **NFR-3.1** Every command is safe to rerun; destructive actions require an
  explicit flag or interactive confirmation and honor ownership markers.
- **NFR-3.2** Secrets (keys, passwords, kubeconfig) live only in gitignored
  `state/secrets/`; large cached downloads live in `state/cache/`; a pre-commit
  guard rejects accidental commits of key material.
- **NFR-3.3** Long waits print a heartbeat (elapsed, current phase, last error)
  at least every 30 s; failures end with the real underlying error, not a
  generic wrapper message.

## NFR-4 Recoverability

- **NFR-4.1** A laptop reboot is a first-class scenario: `lab up` must bring the
  lab back without manual steps, including known failure modes (DHCP lease
  change, CNI/route loss after reboot, pod crash-loop timers).
- **NFR-4.2** State the lab depends on (which VM, which IP, which keys) is
  discovered or stored in `state/`, never hardcoded in the operator's head.

## NFR-5 Resource fit

- **NFR-5.1** Everything runs on one laptop. The outer VM budget is declared in
  `lab.yaml` (single source of truth). `lab status` warns before capacity is
  exceeded; VM definitions declare their footprint so totals are checkable.

## NFR-6 Audit logging

- **NFR-6.1** Every significant external action — virsh/virt-install and any
  other outer-VM management, kubectl/helm/virtctl and any Kubernetes call, SSH
  to the outer VM or guests, image downloads, and destructive file operations —
  MUST be logged to an append-only log file under `state/logs/`.
- **NFR-6.2** Each entry records a timestamp, the command (or API call) and its
  target, the exit status/outcome, and duration. Secrets (keys, passwords,
  tokens) are never written to the log.
- **NFR-6.3** All external commands flow through one shared runner that
  enforces NFR-6.1/6.2; code must not call subprocess APIs directly, so no
  call can bypass the log.
