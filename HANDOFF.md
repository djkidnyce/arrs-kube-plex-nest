# HANDOFF — arrs-kube-plex-nest

Last updated: 2026-10-21 · Chart version: 1.4.0

Regenerate this file after every change (project convention).

## What this is
A Helm chart for a self-hosted media stack on a single-node kubeadm
Kubernetes cluster: two independent Plex servers (Plex cannot cluster),
SABnzbd behind a gluetun VPN sidecar, Sonarr / Radarr / Lidarr, Prowlarr,
Seerr, Tautulli, and opt-in AudiobookShelf, Dispatcharr, Whisparr,
LazyLibrarian, plus scheduled ClamAV scans and nightly SQLite config backups.

## This release (1.4.0) — image updates
Bumped to current linuxserver STABLE tags (verified via Docker Hub API,
pushed 2026-10-20/21). Only stable; develop/nightly tags deliberately avoided.

| App      | From                              | To                                 |
|----------|-----------------------------------|------------------------------------|
| Plex     | 1.43.3.10828-00f62d37d-ls314      | 1.43.5.11029-6bf8af3f0-ls329       |
| Radarr   | 6.3.0.10514-ls311                 | 6.4.4.10685-ls323                  |
| Prowlarr | 2.5.2.5491-ls156                  | 2.6.5.5623-ls165                   |
| Sonarr   | 4.0.19.2979-ls319                 | 4.0.20.3014-ls1                    |

Left unchanged (stable line has NOT advanced; only develop/nightly have):
Lidarr 3.1.0.4875-ls35, SABnzbd 5.0.4-ls262, Tautulli v2.17.2-ls236.
Not re-checked this release (ghcr, verify before bumping): gluetun v3.41.3,
Seerr v3.4.1, Dispatcharr 0.28.2, AudiobookShelf 2.36.0, Whisparr v3-3.0.0.400,
ClamAV 1.5.

## Deploy
```
cd <repo> && git pull
helm upgrade akpn . -n media -f my-values.yaml      # or ./deploy.sh -f my-values.yaml
```
On deploy.sh: the app picker pre-checks already-deployed apps; leave the
auto-configure checklist EMPTY to upgrade without touching existing config.
Only Plex, Radarr, Prowlarr, Sonarr roll on this release; the rest stay put.

Arr DB migrations are forward-only (6.3->6.4, 2.5->2.6 cannot be downgraded).
Trigger a config backup first:
```
kubectl create job --from=cronjob/config-backup backup-now -n media
```

## Verify after deploy
```
kubectl get pods -n media
kubectl get deploy -n media -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```
Confirm the four rolled pods reach Running on the new tags.

## Known state / open items
- Node RAM reads 7.2Gi (a prior 16Gi bump did not persist). Restore 16Gi;
  memory limits commit to ~309% on the full stack, so a 4-image rollout on
  7.2Gi can churn. The deploy prints node capacity + commitment up front.
- Config PVCs carry helm.sh/resource-policy: keep (Helm cannot delete them).
- VPN rotator is a supervisor (self-heals a stopped tunnel); rotation interval
  resets from my-values on upgrade — set vpn.rotationIntervalSeconds "0" to keep off.
- Pending (next releases): randomized rotation window; PIA alternate-on-rotation
  profiles (needs scoped RBAC); SABnzbd 5.1.0 (still nightly/RC upstream).

## Guardrails
- Pin STABLE image tags only. Docker Hub "last pushed" ordering surfaces
  develop/nightly first for the arrs — never pin those.
- No secrets in the repo. Machine-specific values (NAS host/share, VPN creds,
  real IPs) live in gitignored my-values.yaml and *.local* files.
