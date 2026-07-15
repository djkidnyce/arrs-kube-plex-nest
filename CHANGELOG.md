# Changelog

All notable changes to this Helm chart are documented here.

## [1.1.0] - 2026-07-14

### Fixed
- **Deploy-blocking:** removed `templates/secrets.yaml` and `templates/namespace.yaml`.
  Both collided with the resources deploy.sh creates imperatively, failing first
  installs with "invalid ownership metadata" and risking credential overwrite on
  upgrades. Secrets are now imperative-only.
- **Plex autoscaling removed.** Plex cannot scale horizontally (SQLite config,
  no clustering, no session sharing). The HPA created empty unclaimed servers.
  Replaced with `plex.replicas` (default 2) running independent Plex servers,
  each with its own config PVC and LoadBalancer port.
- **gluetun control-server auth.** gluetun >= v3.40 requires authentication on
  all control-server routes. deploy scripts now generate a random API key in the
  `gluetun-control-auth` Secret; rotate.sh authenticates with `X-API-Key`.
- Removed `OPENVPN_USER`/`OPENVPN_PASSWORD` env vars that mapped the entire
  two-line credential file into both variables.
- scan.sh: freshclam failures are no longer silently swallowed; infected-count
  no longer double-prints "0".
- deploy.sh: replaced `eval` prompt assignment (quote-injection) with `printf -v`;
  fixed `--rollback-on-failure` to be Helm-version aware (`--atomic` on v3).
- README: resolved committed merge-conflict markers.

### Security
- All images version-pinned (no `:latest`); `values.schema.json` rejects `:latest`.
- Removed the filebrowser container (default admin/admin credentials) and its
  PVCs/Service. `.ovpn` files now load via `deploy.sh --ovpn-dir` into the
  `vpn-ovpn-configs` Secret — never stored in the repo.
- Per-app NetworkPolicies replace the blanket intra-namespace allow: SABnzbd is
  reachable only from the *arrs, the *arrs only from Overseerr; gluetun's
  control API (8000) is unreachable from other pods.
- Pod hardening on every workload: `seccompProfile: RuntimeDefault`, dropped
  capabilities (LSIO containers keep only what s6 needs), 
  `allowPrivilegeEscalation: false`, `automountServiceAccountToken: false`.
- ClamAV CronJobs run non-root (1000:1000) with capabilities dropped.
- SMB mount tightened from `0777`+`noperm` to `0770`.
- ClamAV webhook URL (a bearer credential on ntfy) is no longer cached on disk.
- Plex probes moved to the canonical unauthenticated `/identity` endpoint.
- Resource requests/limits added to gluetun, rotator, init, and ClamAV containers.

### Added
- `nas.host` is now required at render time (clear failure instead of `//` mount).
- `values.schema.json`, `.helmignore`.
- `tests/validate.py` offline render/cross-reference harness.
- `.github/workflows/ci.yaml`: helm lint + template + kubeconform + shellcheck.

## [1.0.1] - 2026-06-19

### Changed
- Bumped the chart version from `1.0.0` to `1.0.1`.
- Added a release history reference in the README so the latest changes are easier to find.
- Documented the current release notes for the chart.

## [1.0.0] - 2026-06-19

### Added
- Initial release of the `arrs-kube-plex-nest` chart.
- Included deployment templates and configuration for Plex, SABnzbd, VPN, *arr services, ClamAV scanning, networking, secrets, and storage support.
