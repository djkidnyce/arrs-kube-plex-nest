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

## Connecting the apps

Configure apps by their cluster DNS names, never by IP or the plex.tv server
picker: pod IPs change on restart, DNS names do not. `helm get notes` prints the
exact values, but the essentials:

- **arrs to SABnzbd:** host `sabnzbd`, port 8080, SSL off (deploy.sh does this
  automatically unless you pass `--no-autowire`).
- **Overseerr/Tautulli to Plex:** `plex-0.plex-headless.<ns>.svc.cluster.local`
  port 32400, SSL off (and `plex-1...` for the second server). Use manual entry,
  not the plex.tv dropdown.

### Auto-wiring

After deploy, `deploy.sh` reads the API keys from the config PVCs and registers
SABnzbd as a download client in Sonarr, Radarr, and Lidarr. It is restore-safe:
it GETs existing download clients first and skips any app that already has
SABnzbd, so a restored or hand-configured app is never touched or duplicated.
Disable with `--no-autowire` or `autowire.enabled: false`.

### Prowlarr

`prowlarr.enabled` (default true) adds Prowlarr for centralized indexer
management. Add your indexers once in Prowlarr and it syncs them to the arrs.
In Prowlarr, add each arr under Settings, using host `sonarr`/`radarr`/`lidarr`
and the app's API key. Prowlarr is reachable by port-forward, or set
`expose.prowlarr: true`.

### Seerr (was Overseerr)

Overseerr and Jellyseerr merged into [Seerr](https://docs.seerr.dev) and are
deprecated. This chart runs the native `seerr` image, which is rootless and
stores data at `/app/config`. An existing Overseerr database on the `seerr-config`
PVC migrates automatically on first start, and the nightly backup covers it, so
the migration is recoverable.

### ClamAV scan scope

ClamAV scans `/mnt/media`, so completed downloads under
`/mnt/media/usenet/complete` are scanned as they arrive. The config backups
(`/mnt/media/.backups`), scan reports (`/mnt/media/.clamav-reports`), and the
incomplete/working download directory are excluded automatically, since
scanning backup archives and partial in-progress files is wasted work.

### SABnzbd download performance

By default everything stays on the SMB share (`sabnzbd.downloads.enabled:
false`), so no local disk is required on the node. Downloading and unpacking on
a network share is slower because of the heavy random I/O, so if your node has
free local disk you can set `sabnzbd.downloads.enabled: true`. That moves the
incomplete/unpack directory to a local `sabnzbd-downloads` PVC while completed
files still land on `/mnt/media` for same-filesystem arr imports. Only enable it
if the node actually has room for `sabnzbd.downloads.size`; on a diskless node
it will fill the root filesystem or fail to bind. Either way, the SABnzbd
connection count (Config to Servers) is the other thing to check if downloads
are slow.

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

### Config backups

Every app here stores its state in a SQLite database on a config PVC, which
uses the cluster's default StorageClass. On a single-node install that is one
disk with no redundancy: losing it loses every library, watch history, and
download setting. The media on the NAS is unaffected; the configuration is not.

A nightly CronJob copies each config volume to the media share. Databases are
copied with SQLite's online backup API, so nothing is stopped and a database
being written mid-copy cannot produce a silently corrupt archive.

```yaml
backup:
  enabled: true
  schedule: "0 3 * * *"
  destination: "/mnt/media/.backups"
  keep: 14
  apps: [sonarr, radarr, lidarr, seerr, tautulli, sabnzbd]
```

Plex is excluded by default: its config lives in StatefulSet volumeClaim-
Templates and can reach tens of gigabytes of metadata and thumbnails, most of
which Plex regenerates. Add `plex-config-plex-0` style claims yourself if you
want it.

Run one immediately:

```bash
kubectl create job --from=cronjob/config-backup backup-now -n media
kubectl logs -f job/backup-now -n media
```

#### Restoring a config backup

```bash
kubectl scale deployment sonarr --replicas=0 -n media
kubectl wait --for=delete pod -l app=sonarr -n media --timeout=120s
```

Start a throwaway pod with both the config PVC and the media share, then
extract the archive over the config volume:

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: restore
  namespace: media
spec:
  restartPolicy: Never
  containers:
    - name: restore
      image: docker.io/library/python:3.13-alpine
      command: ["sleep", "3600"]
      volumeMounts:
        - name: cfg
          mountPath: /config
        - name: media
          mountPath: /mnt/media
  volumes:
    - name: cfg
      persistentVolumeClaim:
        claimName: sonarr-config
    - name: media
      persistentVolumeClaim:
        claimName: media-pvc
EOF

kubectl exec -n media restore -- sh -c 'ls -1 /mnt/media/.backups/sonarr/'
kubectl exec -n media restore -- sh -c \
  'rm -rf /config/* && tar xzf /mnt/media/.backups/sonarr/sonarr-<STAMP>.tar.gz -C /config'
kubectl delete pod restore -n media
kubectl scale deployment sonarr --replicas=1 -n media
```

### Keeping local settings out of git

Copy `my-values.example.yaml` to `my-values.yaml`, edit it, and deploy with it.
`my-values.yaml` is gitignored, so node IPs, hostnames, and share names stay on
your machine:

```bash
cp my-values.example.yaml my-values.yaml
./deploy.sh -f my-values.yaml
```

Only the keys you want to override need to be present. Credentials never go in
this file: deploy.sh creates those as Secrets directly.

### Exposing the web UIs

`expose.mode` controls how services are published:

- **`nodePort`** (default): each exposed service gets a pinned port on every
  node IP. Works regardless of whether a load balancer controller is present,
  and regardless of whether MetalLB's L2 announcements reach your clients.
- **`loadBalancer`**: requires MetalLB or a cloud LB. See the MetalLB note
  below before choosing this on a Calico cluster.
- **`clusterIP`**: nothing published; reach UIs with `kubectl port-forward`.

Only Plex and Overseerr are exposed by default. Enable others individually:

```bash
helm upgrade akpn . -n media --set expose.sonarr=true --set expose.sabnzbd=true
```

Each exposed service automatically gets a matching NetworkPolicy. Without one,
the port is published but default-deny drops the traffic, which looks exactly
like a broken service.

**Enable each app's own authentication before exposing it.** These UIs have
full download and filesystem control, and the exposure itself provides no
authentication.

### MetalLB with Calico

If you use `expose.mode: loadBalancer` with Calico's VXLAN overlay, MetalLB may
bind its ARP responder to `vxlan.calico` instead of your real NIC. The Service
gets an IP, works from the node itself, and is unreachable from everywhere
else. Pin the interface:

```yaml
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lan-l2
  namespace: metallb-system
spec:
  ipAddressPools: ["lan-pool"]
  interfaces: ["eth0"]
```

Verify with `kubectl get servicel2status -A`. If that is empty, nothing is
being announced no matter what IPs the Services show.

### SABnzbd configuration

SABnzbd holds its config in memory and rewrites `sabnzbd.ini` on shutdown, so
edits made to a running instance are silently discarded. The chart therefore
seeds settings with an init container before SABnzbd starts:

- `enable_https = 0` so the *arrs can talk to it over plain HTTP internally
- `inet_exposure` (default 4) so the UI is reachable once published, since
  NodePort and LoadBalancer both translate the source address and SABnzbd
  otherwise treats every client as external
- `host_whitelist` seeded with the cluster DNS names; add node IPs or
  hostnames you browse to via `sabnzbd.config.hostWhitelist`

Set a username and password in Config → General when exposing it.

### Changing nas.host after install

The StorageClass and PersistentVolume are immutable, so Helm cannot repoint
them. The share data is untouched by this (`reclaimPolicy: Retain`):

```bash
kubectl scale statefulset plex --replicas=0 -n media
kubectl scale deployment sabnzbd sonarr radarr lidarr --replicas=0 -n media
kubectl delete pvc media-pvc -n media
kubectl delete pv media-pv
kubectl delete storageclass smb-media
./deploy.sh
```

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

### ClamAV

Scans write a timestamped report to `clamav.reportDir` (default
`/mnt/media/.clamav-reports`), readable from any SMB client, keeping the last
`clamav.keepReports` files. Signature updates run on their own schedule via the
`clamav-definitions` CronJob, so scans start with current definitions and you
can refresh without a full scan:

```bash
kubectl create job --from=cronjob/clamav-definitions defs-now -n media
```

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
