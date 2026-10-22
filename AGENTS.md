# AGENTS.md — arrs-kube-plex-nest

Guidance for AI agents (ChatGPT/Codex, Claude, etc.) working in this repo.
This is the standard file such tools read first. Read HANDOFF.md for the
current state of the deployment.

## Project
A Helm chart deploying a self-hosted media stack to a SINGLE-NODE kubeadm
Kubernetes cluster (control plane also schedules workloads). Not a generic
cloud chart; it is tuned for this one homelab topology.

## Architecture (assume these; do not redesign without cause)
- Kubernetes: kubeadm, v1.36, single node, Helm 4 (server-side apply).
- CNI: Calico in VXLAN mode (pod MTU 1450).
- Networking: services exposed via NodePort (MetalLB was unreliable on this
  network and is not used). Reach apps at <node-ip>:<nodePort>.
- Storage: media on an SMB share (TrueNAS) via the SMB CSI driver (RWX,
  Retain). App config on local-path (RWO, node-local) — so pods with config
  are pinned to the node that holds their PVC.
- Plex: StatefulSet of N INDEPENDENT servers (Plex cannot cluster), per-pod
  NodePort at basePort+N, headless service for stable DNS.
- VPN: SABnzbd shares a gluetun OpenVPN sidecar's network namespace (kill
  switch). A vpn-rotator sidecar supervises the tunnel via gluetun's control
  API and rotates the exit server.

## Repo layout
- Chart.yaml — chart version (bump on every change).
- values.yaml — all config; image pins; expose toggles + nodePorts.
- my-values.example.yaml — template for the user's gitignored my-values.yaml.
- templates/ — manifests (Go templates; helpers in _helpers.tpl).
- files/scripts/ — shell scripts embedded into ConfigMaps (backup.py,
  scan.sh, freshclam.sh, sab-seed.sh, rotate.sh).
- tests/ — offline harness: render.py (mini Go-template renderer),
  validate.py (schema + cross-reference checks), test_backup.py,
  test_sab_seed.sh, test_scan_find.sh.
- deploy.sh — interactive installer: prereqs, secrets, whiptail app picker,
  opt-in auto-wiring, Plex claim, node resource report, endpoint table.
- .github/workflows/ci.yaml — helm lint, helm template, kubeconform, shellcheck.

## How to test (always, before delivering)
Offline (no cluster needed):
```
python3 tests/render.py --set nas.host=1.1.1.1 > /tmp/r.yaml && python3 tests/validate.py /tmp/r.yaml
python3 tests/test_backup.py && sh tests/test_sab_seed.sh && sh tests/test_scan_find.sh
bash -n deploy.sh
```
Render with apps toggled on/off (--set <app>.enabled=true/false) to confirm
gating. CI additionally runs real helm, kubeconform, and shellcheck on push.

## Conventions (follow these)
- Pin STABLE image tags only, exact versions, never `latest` or develop/
  nightly. Docker Hub "last pushed" ordering lists develop/nightly FIRST for
  the arrs — verify the stable tag (e.g. the one `latest` points to), do not
  grab the newest push. Authoritative source: Docker Hub tags API
  (hub.docker.com/v2/namespaces/linuxserver/repositories/<img>/tags).
- No secrets in the repo. NAS host/share, VPN credentials, real IPs, and
  network notes live ONLY in gitignored my-values.yaml / *.local* files.
  Never add real addresses or credentials to tracked files.
- Config/data PVCs must carry `helm.sh/resource-policy: keep` so Helm can
  never delete them on upgrade or when an app is disabled.
- Secure-by-design: least-privilege securityContexts, default-deny ingress
  NetworkPolicies, minimal container capabilities.
- Bump Chart.yaml version on every change; regenerate HANDOFF.md every change.

## Gotchas learned the hard way
- gluetun binds its provider at container start; it cannot switch providers
  live. The rotator rotates servers within one provider via the control API.
- gluetun's healthcheck restarts a running-but-unhealthy tunnel, but NOT an
  intentionally stopped one — the rotator supervisor must ensure it is never
  left stopped.
- gluetun on Calico VXLAN: tun0 MTU 1500 > pod MTU 1450, so TLS handshakes
  drop. A TCPMSS clamp on tun0 (via gluetun post-rules) fixes it.
- ClamAV image is Alpine/BusyBox: its `find` rejects GNU-only predicates
  (e.g. -false). Keep scan.sh POSIX.
- The node is RAM-constrained; do not run a ClamAV full scan or a large
  multi-image rollout alongside other heavy work.

## Deliver
Changes are delivered as git-am patches plus a full zip (the user applies
with `git am` and pushes). Keep the working tree clean before applying.
