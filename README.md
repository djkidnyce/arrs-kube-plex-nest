# 🎬 Arrs Kube Plex Nest — Self-Hosted Kubernetes Media Server

A production-ready Helm chart for a complete self-hosted media server stack, designed for **TrueNAS SMB storage** and deployable from **Windows Server or Linux**.

> **New to this?** Open [`setup-guide.html`](setup-guide.html) in any browser for a visual step-by-step walkthrough with an architecture diagram.

---

## What's Included

| Service | Image | Purpose |
|---------|-------|---------|
| **Plex** | `lscr.io/linuxserver/plex` | Media server — autoscales 1–3 replicas via HPA |
| **SABnzbd** | `lscr.io/linuxserver/sabnzbd` | Usenet downloader — all traffic routed through VPN |
| **gluetun** | `ghcr.io/qdm12/gluetun` | VPN sidecar (OpenVPN) with kill-switch |
| **Sonarr** | `lscr.io/linuxserver/sonarr` | TV show automation |
| **Radarr** | `lscr.io/linuxserver/radarr` | Movie automation |
| **Lidarr** | `lscr.io/linuxserver/lidarr` | Music automation |
| **Overseerr** | `lscr.io/linuxserver/overseerr` | Media request management |
| **Tautulli** | `lscr.io/linuxserver/tautulli` | Plex analytics |
| **ClamAV** | `clamav/clamav` | Daily + monthly antivirus scans with webhook alerts |
| **filebrowser** | `filebrowser/filebrowser` | Web UI for uploading `.ovpn` files |

---

## Architecture

```
                        ┌─────────────────────── namespace: media ─────────────────────────┐
                        │                                                                    │
  ⚡ HPA (1–3 replicas) │   ┌──────────┐  ┌──────────┐  ┌──────────┐                     │
   targeting 70% CPU ──►│   │  plex-0  │  │  plex-1  │  │  plex-2  │  (StatefulSet)       │
                        │   │  :32400  │  │  :32401  │  │  :32402  │  each has own PVC    │
                        │   └────┬─────┘  └────┬─────┘  └────┬─────┘                     │
                        │        └──────────────┴──────────────┘                           │
                        │                       │ media-pvc (RWX · SMB · TrueNAS)          │
                        │   ┌───────────────────┴────────────────────────────────────┐     │
                        │   │  SABnzbd Pod (shared network namespace)                │     │
                        │   │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │     │
                        │   │  │ gluetun  │ │ sabnzbd  │ │ rotator  │ │filebrowsr│ │     │
                        │   │  │  VPN+KS  │ │  :8080   │ │ interval │ │  :8888   │ │     │
                        │   │  └──────────┘ └──────────┘ └──────────┘ └──────────┘ │     │
                        │   │  All egress exits via VPN · RFC-1918 bypasses tunnel  │     │
                        │   └────────────────────────────────────────────────────────┘     │
                        │                                                                    │
                        │   Sonarr :8989  Radarr :7878  Lidarr :8686                       │
                        │   Overseerr :5055 (external)  Tautulli :8181                     │
                        │   ClamAV CronJobs (daily 2:30 AM · monthly 4:00 AM 1st)          │
                        └────────────────────────────────────────────────────────────────────┘
```

**Key design decisions:**
- Plex runs as a **StatefulSet** (not Deployment) so each HPA replica gets its own `/config` PVC — avoids RWO PVC conflicts
- SABnzbd's VPN is scoped to the pod only — other services are unaffected
- VPN rotation interval is **hot-reloadable** via ConfigMap without restarting pods
- All container images are Linux-only; `nodeSelector: kubernetes.io/os: linux` ensures they land on Linux nodes even in mixed clusters

---

## Prerequisites

- **Kubernetes cluster** with at least one Linux worker node (k3s, kubeadm, RKE2, etc.)
- **TrueNAS** (or other NAS) with an SMB share accessible from the cluster
- **OpenVPN provider** account (tested with PrivadoVPN — any provider that supplies `.ovpn` files works)
- **kubectl** and **helm** on the machine you're deploying from

---

## Quick Start

### Clone the repo

```bash
git clone https://github.com/djkidnyce/arrs-kube-plex-nest.git
cd arrs-kube-plex-nest
```

### Windows Server

```powershell
# Step 1: Install or upgrade kubectl + helm (checks for existing installs first)
.\install-tools.ps1

# Step 2: Open a new PowerShell window, then configure kubeconfig
#   Copy from your cluster (k3s example):
#   scp user@<node-ip>:/etc/rancher/k3s/k3s.yaml $env:USERPROFILE\.kube\config
#   Then replace 127.0.0.1 with your node IP if needed

# Step 3: Deploy
.\deploy.ps1                        # interactive
.\deploy.ps1 -Namespace media       # custom namespace
.\deploy.ps1 -DryRun                # preview only
```

### Linux

```bash
# Step 1: Install or upgrade kubectl + helm (checks for existing installs first)
chmod +x install-tools.sh deploy.sh
./install-tools.sh

# Step 2: Configure kubeconfig (k3s example)
mkdir -p ~/.kube
scp user@<node-ip>:/etc/rancher/k3s/k3s.yaml ~/.kube/config
chmod 600 ~/.kube/config

# Step 3: Deploy
./deploy.sh                         # interactive
./deploy.sh -n media                # custom namespace
./deploy.sh --dry-run               # preview only
```

> Both scripts will prompt you for SMB credentials, Plex claim token, VPN credentials, and a ClamAV webhook URL. Passwords are entered as hidden prompts and are never written to disk.

---

## Configuration

The deploy scripts prompt for NAS host, share name, and all credentials interactively — you don't need to edit `values.yaml` for those. Other key settings:

```yaml
# NAS / TrueNAS SMB share
# nas.host and nas.mediaShare are collected by the deploy script at runtime.
# You can also pass them directly:
#   helm upgrade --install akpn . --set nas.host=192.168.1.100 --set nas.mediaShare=media
nas:
  host: ""           # set via deploy script prompt
  mediaShare: "media"

# Plex autoscaling
plex:
  autoscaling:
    enabled: true
    minReplicas: 1
    maxReplicas: 3
    targetCPUUtilizationPercentage: 70

# VPN rotation (0 = disabled; change live via: kubectl edit cm vpn-config)
vpn:
  rotationIntervalSeconds: "3600"

# ClamAV notifications
clamav:
  enabled: true
  notificationType: "ntfy"   # ntfy | discord | slack | gotify | generic
```

See `values.yaml` for the full reference including resource limits and storage sizes.

---

## Services & Ports

| Service | Port | External? | Notes |
|---------|------|-----------|-------|
| `plex-0` | 32400 | ✅ LoadBalancer | Always running |
| `plex-1` | 32401 | ✅ LoadBalancer | HPA scale-up |
| `plex-2` | 32402 | ✅ LoadBalancer | HPA scale-up |
| `seerr` (Overseerr) | 5055 | ✅ LoadBalancer | Request management |
| `sabnzbd` | 8080 | ClusterIP | Port-forward to access |
| `sabnzbd-filebrowser` | 8888 | ClusterIP | Upload `.ovpn` files here |
| `sabnzbd-vpn` | 8000 | ClusterIP | gluetun control API |
| `sonarr` | 8989 | ClusterIP | |
| `radarr` | 7878 | ClusterIP | |
| `lidarr` | 8686 | ClusterIP | |
| `tautulli` | 8181 | ClusterIP | |

Port-forward any ClusterIP service to your local machine:
```bash
kubectl port-forward svc/sabnzbd-filebrowser 8888:8888 -n media
```

---

## Post-Deploy Steps

1. **Upload `.ovpn` file** — port-forward the filebrowser, log in (default `admin`/`admin`, change immediately), upload your provider's `.ovpn` file
2. **Restart SABnzbd** — `kubectl rollout restart deployment/sabnzbd -n media`
3. **Claim Plex** — visit `http://<plex-0-lb-ip>:32400/web`, use the claim token you entered during deploy (get a fresh one at https://plex.tv/claim — valid 4 min)
4. **Connect Sonarr/Radarr to SABnzbd** — host: `sabnzbd.media.svc.cluster.local`, port `8080`, API key from SABnzbd settings
5. **Verify VPN** — `kubectl port-forward svc/sabnzbd-vpn 8000:8000 -n media`, then `curl http://localhost:8000/v1/openvpn/status`

---

## VPN Rotation

Change the rotation interval at any time **without restarting pods**:
```bash
kubectl edit configmap vpn-config -n media
# Edit rotation-interval-seconds (0 = disabled)
```
The `vpn-rotator` container re-reads the file on every loop iteration.

---

## ClamAV Alerts

The scan script supports four notification platforms. Set `clamav.notificationType` in `values.yaml`:

| Platform | Webhook URL format |
|----------|--------------------|
| `ntfy` | `https://ntfy.sh/YOUR_TOPIC` |
| `discord` | `https://discord.com/api/webhooks/...` |
| `slack` | `https://hooks.slack.com/services/...` |
| `gotify` | `https://your-gotify/message?token=...` |
| `generic` | Any HTTP POST endpoint |

Run a manual scan immediately:
```bash
kubectl create job --from=cronjob/clamav-daily manual-scan-$(date +%s) -n media
```

---

## Secrets (never in git)

The deploy scripts create all secrets **imperatively** — they are never written to files. The `templates/secrets.yaml` in this repo contains only `REPLACE_ME` placeholder values and should not be applied directly.

If you need to update a secret later:
```bash
# Update VPN credentials
kubectl create secret generic vpn-credentials \
  --from-file=openvpn.cred=/path/to/cred-file \
  --namespace=media --dry-run=client -o yaml | kubectl apply -f -
```

---

## Upgrading

```bash
# Pull latest chart changes
git pull

# Check/upgrade your tools first
.\install-tools.ps1    # Windows
./install-tools.sh     # Linux

# Re-deploy (Helm upgrades in-place)
.\deploy.ps1           # Windows
./deploy.sh            # Linux
```

---

## Troubleshooting

```bash
# Check all pod status
kubectl get pods -n media

# SABnzbd VPN logs
kubectl logs -l app=sabnzbd -c gluetun -n media --tail=50

# Plex HPA status
kubectl describe hpa plex-hpa -n media

# ClamAV last scan result
kubectl logs -l scan-type=daily -n media --tail=100
```

---

## Contributing

Pull requests welcome. Before submitting:
- Test on a real cluster (`helm template` + `kubectl apply --dry-run=server`)
- Keep secrets out of commits — use the imperative `kubectl create secret` pattern
- For new notification platforms, add them to `files/scripts/scan.sh` and update the docs

---

## License

MIT — see [LICENSE](LICENSE) for details.

---

*Built with Helm v4.x · Tested on k3s · TrueNAS SCALE SMB 3.1.1 + seal*
