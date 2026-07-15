# Hardening release — v1.1.0 change description

Branch: `hardening-fixes` · Chart `1.0.1` → `1.1.0`

This release fixes four deploy-blocking bugs, removes the Plex autoscaling
design (which cannot work), and hardens every workload in the chart. Suitable
as the PR description or release notes.

## Why Plex autoscaling was removed

Plex Media Server cannot scale horizontally. Its configuration database is
SQLite (single writer, no clustering) and there is no session sharing between
instances; clients pin to one server. The old HPA scaled the StatefulSet, but
each new replica got its own EMPTY config PVC — an unclaimed server with no
library, not extra capacity. Claim tokens are single-use with a 4-minute
expiry, so replicas could not even claim themselves. Every `helm upgrade`
also reset `replicas` to `minReplicas`, fighting the HPA.

Replacement: `plex.replicas` (default `2`) runs that many INDEPENDENT Plex
servers. plex-0 and plex-1 each keep their own config PVC and LoadBalancer
port (32400, 32401), both mount the same media share, and each is claimed
once. Transcode capacity scales vertically via `plex.resources`.

## Deploy-blocking fixes

1. **Removed `templates/secrets.yaml`.** deploy.sh creates the same four
   Secrets imperatively before `helm install`, so the first install failed
   with "invalid ownership metadata". Had Helm ever owned them, every upgrade
   would have overwritten real credentials with `REPLACE_ME`. Secrets are now
   imperative-only and never part of the release.
2. **Removed `templates/namespace.yaml`.** Same ownership conflict: the
   namespace was pre-created by deploy.sh and by `--create-namespace`.
3. **gluetun control-server authentication.** gluetun >= v3.40 requires auth
   on all control-server routes, so the VPN rotator's bare API calls returned
   401 against current images. deploy.sh now generates a random 48-character
   API key into the `gluetun-control-auth` Secret (config.toml + apikey);
   rotate.sh authenticates with an `X-API-Key` header. gluetun is pinned to
   v3.41.1.
4. **Removed `OPENVPN_USER`/`OPENVPN_PASSWORD` env vars.** Both mapped the
   entire two-line credential file into each variable. Auth now flows only
   through the patched `auth-user-pass` credential file.

## Security hardening

- **All images version-pinned.** No `:latest` anywhere; `values.schema.json`
  rejects `:latest` at lint time. Pinned: Plex 1.43.3, SABnzbd 5.0.4,
  Sonarr 4.0.19, Radarr 6.3.0, Lidarr 3.1.0, Overseerr 1.35.0,
  Tautulli 2.17.2, gluetun v3.41.1, ClamAV 1.5, curl 8.14.1, busybox 1.37.0.
- **filebrowser removed** (shipped default admin/admin inside the VPN pod).
  `.ovpn` files now load at deploy time via `./deploy.sh --ovpn-dir <dir>`
  into the `vpn-ovpn-configs` Secret — never committed to the repo
  (`*.ovpn` is gitignored). Its two PVCs and Service are gone.
- **Per-app NetworkPolicies** replace the blanket intra-namespace allow,
  which had let any compromised pod reach every other pod. Now: Plex (32400)
  and Overseerr (5055) accept external ingress; SABnzbd accepts only the
  *arrs on 8080; the *arrs accept only Overseerr; gluetun's control API
  (8000) is unreachable from other pods (the rotator uses localhost).
- **Pod security on every workload:** `seccompProfile: RuntimeDefault`,
  `allowPrivilegeEscalation: false`, `automountServiceAccountToken: false`,
  capabilities dropped to ALL (LSIO containers re-add only what s6 init
  needs; gluetun re-adds only NET_ADMIN). Sidecar/init containers run
  non-root with read-only root filesystems.
- **ClamAV runs non-root** (1000:1000, caps dropped) instead of uid 0 with
  the whole library mounted.
- **SMB mount tightened** from `0777` + `noperm` to `0770`.
- **ClamAV webhook URL no longer cached on disk** (an ntfy topic URL is a
  bearer credential).
- **deploy.sh `eval` prompt assignments replaced with `printf -v`**
  (single-quote input broke, or worse, executed).

## Reliability and correctness

- `nas.host` is required at render time — clear error instead of a broken
  `///media` mount source.
- Plex probes moved to `/identity`, the canonical unauthenticated endpoint.
- scan.sh: freshclam failures were silently swallowed (exit status of `tail`
  was checked); infected-count could print "0 0".
- Helm-version-aware rollback flag: `--atomic` on v3, `--rollback-on-failure`
  on v4 (the old script passed a v4-only flag unconditionally).
- `clamav.enabled=false` now also removes the clamav ConfigMap.
- Resource requests/limits on every container, including gluetun, the
  rotator, init containers, and ClamAV jobs.
- README rebuilt (the committed file contained unresolved merge-conflict
  markers); setup-guide.html updated to the new architecture.
- metrics-server install step removed from deploy scripts (nothing needs it).

## Testing added

- `tests/render.py` + `tests/validate.py`: offline render and validation
  harness — 166 checks covering Kubernetes 1.29 strict schema validation,
  PVC/Secret/ConfigMap reference integrity, Service selector/port matching,
  NetworkPolicy flow assertions, script embedding, image pinning, replica
  and probe invariants, and a negative test for missing `nas.host`.
- `.github/workflows/ci.yaml`: real `helm lint --strict`, `helm template`
  (default and alternate values), kubeconform, shellcheck, and the offline
  harness on every push.

## Upgrade notes

- Deploy with `./deploy.sh --ovpn-dir /path/to/ovpn/files`. Existing SMB/VPN
  Secrets are kept if present; the gluetun API key is generated on first run.
- Claim each Plex server separately (fresh token per server):
  see `helm get notes akpn -n media`.
- If upgrading an existing release, delete the old HPA and filebrowser
  leftovers if Helm does not prune them:
  `kubectl delete hpa plex-hpa svc/sabnzbd-filebrowser svc/sabnzbd-vpn pvc/vpn-configs pvc/filebrowser-db -n media --ignore-not-found`
