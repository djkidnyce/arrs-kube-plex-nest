# Arrs Kube Plex Nest

Self-hosted Kubernetes media server stack: Plex, SABnzbd behind a VPN kill-switch,
Sonarr / Radarr / Lidarr, Overseerr, Tautulli, and scheduled ClamAV scanning.
Media lives on a TrueNAS (or any) SMB share via the Kubernetes SMB CSI driver.

> Release history: see [CHANGELOG.md](CHANGELOG.md).

## What's included

| Service | Image | Purpose |
|---------|-------|---------|
| Plex | `lscr.io/linuxserver/plex` | Media server — N independent servers (see below) |
| SABnzbd | `lscr.io/linuxserver/sabnzbd` | Usenet downloader, all traffic via VPN |
| gluetun | `ghcr.io/qdm12/gluetun` | OpenVPN sidecar with kill-switch, scoped to the SABnzbd pod |
| Sonarr / Radarr / Lidarr | `lscr.io/linuxserver/*` | TV / movie / music automation |
| Overseerr | `lscr.io/linuxserver/overseerr` | Media request management (external access) |
| Tautulli | `lscr.io/linuxserver/tautulli` | Plex analytics |
| ClamAV | `clamav/clamav` | Daily quick scan + monthly full scan with webhook alerts |

All images are version-pinned in `values.yaml`. No `:latest`.

## Plex: why there is no autoscaling

Plex Media Server cannot scale horizontally. Its configuration database is
SQLite (single writer, no clustering), there is no session sharing between
instances, and clients pin to a single server. An HPA adding replicas would
only create empty, unclaimed servers.

Instead, `plex.replicas` (default **2**) runs that many **independent** Plex
servers. Each gets its own config PVC and its own LoadBalancer port
(`basePort`, `basePort+1`, ...), and all of them mount the same media share.
Claim and configure each one once; NOTES.txt walks through it. Scale transcode
capacity vertically via `plex.resources`, or add hardware transcoding
(mount `/dev/dri` with a device plugin).

## Architecture

```
                 namespace: media  (all ingress default-deny)
 ┌──────────────────────────────────────────────────────────────────┐
 │  plex-0 :32400   plex-1 :32401     ← independent servers (LB)    │
 │        └──────┬───────┘                                           │
 │               │  media-pvc (RWX · SMB · TrueNAS)                  │
 │  ┌────────────┴───────────────────────────────┐                   │
 │  │ SABnzbd pod (one network namespace)        │                   │
 │  │  gluetun (VPN+killswitch) · sabnzbd :8080  │                   │
 │  │  vpn-rotator (localhost API, apikey auth)  │                   │
 │  └────────────────────────────────────────────┘                   │
 │  sonarr :8989 · radarr :7878 · lidarr :8686                       │
 │  overseerr :5055 (LB) · tautulli :8181                            │
 │  ClamAV CronJobs (daily 2:30 · monthly 4:00 on the 1st)           │
 └──────────────────────────────────────────────────────────────────┘
```

Key design decisions:

- Plex is a StatefulSet so each server keeps its own `/config` PVC.
- SABnzbd, the *arrs, Overseerr, and Tautulli are single-replica
  `strategy: Recreate` Deployments — they are SQLite-backed and must never
  run two pods against one config volume.
- The VPN kill-switch is scoped to the SABnzbd pod; nothing else routes
  through it. `FIREWALL_OUTBOUND_SUBNETS` lets the *arrs reach SABnzbd's
  ClusterIP.
- gluetun's control server (v3.40+) is API-key authenticated; the key lives
  in the `gluetun-control-auth` Secret and never in the chart.
- `.ovpn` files are loaded into the `vpn-ovpn-configs` Secret at deploy time
  (`./deploy.sh --ovpn-dir ...`) — never committed to the repo.
- NetworkPolicies are per-app: only Plex (32400) and Overseerr (5055) accept
  external ingress; SABnzbd only accepts the *arrs; the *arrs only accept
  Overseerr. Everything else is port-forward only.
- All pods run with `seccompProfile: RuntimeDefault`, dropped capabilities,
  `allowPrivilegeEscalation: false`, and no service account token. LSIO
  containers keep only the caps their s6 init needs. ClamAV runs non-root.

## Prerequisites

- Kubernetes cluster with at least one Linux worker node (k3s, kubeadm, RKE2...)
- A CNI that enforces NetworkPolicy (Calico, Cilium, ...)
- A **block-storage default StorageClass** (local-path, Longhorn, ...). App
  config PVCs use the cluster default and hold SQLite databases — SQLite on
  SMB/NFS corrupts. Only the media share is SMB.
- TrueNAS (or other NAS) with an SMB share reachable from the cluster
- OpenVPN provider account and its `.ovpn` files
- kubectl and helm on the deploy machine (installed automatically if missing)

## Quick start

```bash
git clone https://github.com/djkidnyce/arrs-kube-plex-nest.git
cd arrs-kube-plex-nest
./deploy.sh --ovpn-dir /path/to/ovpn/files      # Linux / macOS
# or
.\deploy.ps1 -OvpnDir C:\path\to\ovpns          # Windows
```

The script installs the SMB CSI driver, prompts for NAS/SMB/VPN credentials
(created imperatively as Secrets — plaintext never touches the chart), loads
your `.ovpn` files into a Secret, generates the gluetun control-server API
key, and runs `helm upgrade --install`.

Non-interactive / GitOps:

```bash
kubectl create secret generic smb-credentials ...      # see deploy.sh
helm upgrade --install akpn . -n media --create-namespace \
  --set nas.host=192.168.1.100 --set nas.mediaShare=media
```

`nas.host` is required — rendering fails without it.

### VPN modes

`vpn.mode` selects how gluetun connects:

- **`native`** (default): gluetun picks servers from its own built-in list for
  `vpn.provider` (privado, mullvad, nordvpn, pia, and
  [many others](https://github.com/qdm12/gluetun-wiki/tree/main/setup/providers)).
  Filter with `vpn.serverCountries` / `serverCities` / `serverHostnames`.
  Credentials come from the `OPENVPN_USER` and `OPENVPN_PASSWORD` keys of the
  `vpn-credentials` Secret. No `.ovpn` files, and server rotation works because
  gluetun reselects on each restart.
- **`custom`**: your own `.ovpn` files, loaded with `deploy.sh --ovpn-dir`.
  gluetun's `OPENVPN_CUSTOM_CONFIG` accepts a **single file**, so
  `vpn.customConfigFile` must name one of the uploaded files. Use this only if
  gluetun has no built-in support for your provider.

### gluetun capabilities

gluetun runs with `drop: ALL` plus exactly five capabilities, each verified as
load-bearing on a live cluster: `NET_ADMIN` (tun0 and iptables), `CHOWN` and
`DAC_OVERRIDE` (writing `/etc/openvpn/target.ovpn`; dropping ALL removes even
root's implicit file powers), and `SETUID`/`SETGID` (openvpn drops to
`nonrootuser`). `NET_RAW` is deliberately omitted: gluetun only wants it for
ICMP health checks and falls back to DNS probes automatically.

### SABnzbd health probes

SABnzbd's `/api` returns 403 without an API key and it exposes no
unauthenticated health endpoint, so its probes are `tcpSocket`. An HTTP probe
can never pass and leaves the pod permanently unready.

### DNS inside the VPN pod

gluetun rewrites the SABnzbd pod's resolv.conf to its own DNS-over-TLS
resolver, so cluster names like `sonarr.media.svc.cluster.local` do NOT resolve
inside that pod. This is by design and costs nothing: the *arrs dial in to
SABnzbd, and SABnzbd only dials out to public usenet hosts. Do not "fix" it
with `DNS_KEEP_NAMESERVER=on` — gluetun's docs mark that debug-only and it
leaks DNS outside the VPN. If something inside the pod must reach a cluster
service, use the Service's ClusterIP (allowed via `FIREWALL_OUTBOUND_SUBNETS`),
not its DNS name.

### Rotating the gluetun API key

`deploy.sh` generates the `gluetun-control-auth` Secret once and keeps it on
reruns. If you rotate it manually, running pods keep the old value, so follow
any rotation with:

```bash
kubectl rollout restart deployment/sabnzbd -n media
```

### SABnzbd download paths

Every pod mounts the same `media-pvc` at `/mnt/media`, so point SABnzbd's
temporary and complete download folders at subdirectories of it (e.g.
`/mnt/media/usenet/incomplete`, `/mnt/media/usenet/complete`). Imports into
the library are then instant server-side renames on the NAS instead of a
copy back across the network.

## Security model

Threat model: SABnzbd handles untrusted content from the internet; Overseerr
and Plex are exposed to users. Controls:

- Default-deny ingress; explicit per-app allows only (see
  `templates/networkpolicy.yaml`).
- Secrets are created imperatively by the deploy scripts and are never part
  of the Helm release, so `helm upgrade` can never overwrite or leak them.
- gluetun control API requires an API key (48-char random, generated at deploy).
- SMB share is mounted `0770` with wire encryption (`seal`), not world-writable.
- Version-pinned images; `values.schema.json` rejects `:latest`.
- Liveness/readiness probes on every long-running container; resource
  requests/limits everywhere.

Notes: kubelet probe and `kubectl port-forward` traffic is not blocked by
NetworkPolicy on mainstream CNIs. Egress is intentionally unrestricted except
for SABnzbd (kill-switch); add egress policies if your CNI supports them and
you want tighter control.

## Operations

| Task | Command |
|------|---------|
| Claim a Plex server | see `helm get notes akpn -n media` |
| Rotate VPN interval | `kubectl edit configmap vpn-config -n media` |
| Manual ClamAV scan | `kubectl create job --from=cronjob/clamav-daily manual-$(date +%s) -n media` |
| Reload `.ovpn` files | `./deploy.sh --ovpn-dir <dir>` then `kubectl rollout restart deployment/sabnzbd -n media` |
| Web UIs (internal) | `kubectl port-forward svc/<sonarr|radarr|lidarr|sabnzbd|tautulli> <port>:<port> -n media` |

## Testing

`tests/validate.py` renders the chart and checks schema validity plus
cross-references (PVC/Secret/ConfigMap references, service selectors, ports).
CI (`.github/workflows/ci.yaml`) runs `helm lint`, `helm template`,
`kubeconform`, and shellcheck on every push.

## License

MIT
