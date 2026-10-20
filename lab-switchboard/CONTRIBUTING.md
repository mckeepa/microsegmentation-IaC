# Contributing

Keep changes small, testable, and consistent with the single-user lab scope. Before contributing publicly, establish the project's remote repository and reporting/maintenance ownership; this folder has not been published automatically.

## Local Setup

Use Node.js 20 or newer, run `npm ci`, then `npm test` and `npm run dev`. Demo mode uses simulated VM state and must stay on loopback. The application uses Express, browser-native DOM APIs, Lucide icons, and self-hosted IBM Plex fonts; no frontend build step is required.

## Before a Pull Request

1. Run `npm test`, `npm audit --audit-level=moderate`, and `node --check public/app.js`.
2. If touching scripts, run `bash -n scripts/*.sh`. If touching manifests, validate with a compatible Kubernetes API and rerun the deployed RBAC checks.
3. Check desktop and mobile browser layouts, loaded assets, keyboard focus, filtering, confirmation/cancel, and simulated VM actions. Never power-cycle someone else's running lab to test the UI.
4. Run the non-mutating live smoke test only against your own lab and inspect authorization denials as well as successful reads.
5. Include the behavioral change, tests, compatibility assumptions, and documentation updates. Do not include dependencies, test outputs, credentials, VM images, or host-specific private files.

## Design and Security Expectations

Keep Kubernetes lifecycle operations behind the server allowlist, authentication, CSRF verification, explicit confirmation, and scoped RBAC. Do not add arbitrary shell execution, a privileged host socket mount, default admin credentials, force deletion, or broad cluster permissions as shortcuts. Prefer commands that users consciously execute on their workstation over silently moving private keys into the service.

Use semantic controls, accessible names for icons, stable responsive layouts, and text-safe DOM construction. Keep configuration data separate from logic and document guest-service prerequisites honestly. Add focused tests to the existing test file rather than introducing a large framework for a small change. Preserve `package-lock.json`; review dependency/base-image updates and licenses.