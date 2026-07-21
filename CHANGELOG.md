# Changelog

All notable changes to this Helm chart are documented here.

## [1.1.5] - 2026-07-21

Captures everything discovered during the first production deployment. Three
chart bugs, plus configuration that previously required manual intervention.

### Fixed
- **Overseerr was never persisting its database.** The config PVC was mounted
  at `/app/config`, the path used by the upstream image, but this chart runs
  the LinuxServer build, which uses `/config`. Overseerr wrote to ephemeral
  container storage and warned about it on every start; all settings were lost
  on each restart. Now mounted at `/config`.
- **SABnzbd could not be configured reliably.** It rewrites `sabnzbd.ini` from
  memory on shutdown, so edits to a running instance are discarded. Settings
  are now applied by an init container before SABnzbd starts:
  `enable_https = 0` (the *arrs use plain HTTP internally), `inet_exposure`
  (default 4, since NodePort and LoadBalancer translate the source address and
  SABnzbd otherwise refuses every client as "external"), and `host_whitelist`
  seeded with cluster DNS names plus anything in
  `sabnzbd.config.hostWhitelist`.
- **Exposed services were unreachable even when published.** Publishing a port
  without a matching NetworkPolicy meant default-deny dropped the traffic
  silently. Each exposed service now renders its own ingress policy.

### Added
- **`expose` values block.** `expose.mode` of `nodePort` (new default),
  `loadBalancer`, or `clusterIP`, with per-service toggles and pinned
  nodePorts. NodePort is the default because MetalLB's L2 announcements do not
  reach clients on every network, while NodePort works anywhere.
- **ClamAV scan reports** written to `clamav.reportDir` on the media share
  (default `/mnt/media/.clamav-reports`, last `clamav.keepReports` kept), so
  scan history is readable from any SMB client with no UI required.
- **`clamav-definitions` CronJob** updating signatures on its own schedule
  (default every 6 hours), so scans start current and definitions can be
  refreshed without running a scan.
- **`plex.libraries`** declared in values and created automatically over the
  Plex API after each server is claimed. Libraries live in Plex's database, so
  the API is the only supported path.
- deploy.sh asks how many Plex servers to run, then collects one claim token
  per server at the very end, applying each immediately and creating that
  server's libraries. Tokens are single-use with a ~4 minute expiry, so they
  are requested only when they can be consumed at once.
- `my-values.example.yaml`: a documented template for machine-specific
  settings. `my-values.yaml` is already gitignored, so node IPs and hostnames
  stay local rather than being committed.
- README: exposing UIs, MetalLB interface pinning with Calico VXLAN, SABnzbd
  configuration behavior, changing `nas.host` after install (the StorageClass
  and PV are immutable), and ClamAV reporting.

### Testing
- tests/test_sab_seed.sh: 12 checks covering the seed script against real
  sabnzbd.ini shapes. Found and fixed two bugs before release: a trailing
  comma in SABnzbd's own whitelist produced an empty entry
  (`download,,sabnzbd`), and a fresh install left settings unapplied until a
  second restart because the config file did not exist yet. The script now
  writes a minimal config on first boot, verified readable by configobj,
  SABnzbd's own parser.
- tests/render.py `--set` now understands list index syntax (`key[0]=value`),
  without which array values were silently ignored by the test harness.
- tests/validate.py: 231 checks, up from 191. New guards cover the Overseerr
  config path, the SABnzbd seed init container, exposed services having both a
  published port and a matching ingress policy, nodePorts being pinned and in
  range, and the plex-libraries ConfigMap.
- tests/render.py gained `and`, `or`, `printf`, `concat`, `join`, `append`,
  `index`, map-ranging, `$` root access, and Go string-escape handling.
- All four exposure modes and both VPN modes render and validate.

## [1.1.4] - 2026-07-20

First release validated against a real cluster (kubeadm 1.36, Calico, MetalLB,
local-path, TrueNAS SMB). Six defects surfaced that static validation could not
catch, four of them inherited from v1.0. Also folds in the v1.1.3 doc notes,
which were never released.

### Fixed
- **VPN never worked.** `OPENVPN_CUSTOM_CONFIG` was pointed at a directory;
  gluetun requires a single file and exited with "filepath is a directory" on
  every start since v1.0. Reworked into `vpn.mode`:
  - `native` (new default): gluetun's built-in provider support
    (`vpn.provider`, default privado) with `serverCountries`/`serverCities`/
    `serverHostnames` filters. No .ovpn files, working server rotation.
  - `custom`: the .ovpn workflow, with `vpn.customConfigFile` naming the single
    file gluetun actually accepts (required-guarded).
- **gluetun capability set was too small to run.** `drop: ALL` + `NET_ADMIN`
  left it unable to write its config (`chown` then `open ... permission
  denied`, because dropping ALL strips root's implicit file powers) and unable
  to drop privileges (`setuid('nonrootuser') failed`). Now adds CHOWN,
  DAC_OVERRIDE, SETUID, SETGID. NET_RAW intentionally still omitted.
- **SABnzbd was permanently unready.** Probes hit `/api`, which returns 403
  without an API key, so kubelet killed the container in a loop. Switched to
  `tcpSocket`.
- **`openvpn.cred` mount hung the pod** whenever that key was absent from the
  Secret. Now mounted only in custom mode.
- **deploy.sh `--rollback-on-failure` guaranteed failure.** The ClamAV
  definitions PVC is WaitForFirstConsumer and stays Pending until the CronJob
  first fires, so helm's readiness gate could never pass and rolled back
  healthy installs. Flag removed.
- **.ovpn Secret creation hit the 256KiB annotation limit** because it routed
  through client-side apply. Now creates directly.
- deploy.sh: literal `\033[2m` escape codes printed in prompts (`read` does not
  interpret them; switched to ANSI-C quoting).
- deploy.sh: share sizes like `30tb` are normalized to `30Ti` at the prompt
  instead of failing schema validation minutes later inside helm.

### Changed
- **Plex claim token is now the LAST prompt**, asked after helm completes, and
  it immediately restarts plex-0 to consume it. Tokens are single-use with a
  ~4 minute expiry, so asking before a multi-minute install guaranteed expiry.
- deploy.sh writes `OPENVPN_USER`/`OPENVPN_PASSWORD` alongside `openvpn.cred`,
  so switching `vpn.mode` never requires re-entering credentials.
- **startupProbes on every long-running container** (Plex 10 min, apps 5 min).
  On a loaded node, slow first boots were liveness-killed into restart loops
  before they could finish initializing.

### Documentation
- README: VPN modes, the gluetun capability rationale, why SABnzbd uses TCP
  probes, DNS behavior inside the VPN pod (and why not to set
  `DNS_KEEP_NAMESERVER`), and gluetun API key rotation.

### Testing
- tests/validate.py: 191 checks, up from 171. New guards assert the gluetun
  capability set, that `OPENVPN_CUSTOM_CONFIG` is never a directory, native
  mode wiring (credentials present, no init container, no cred mount), non-HTTP
  SABnzbd probes, and startupProbe presence on every app container.
- tests/render.py: added `eq`, `ne`, `not`, `empty`, `default`, and `with`.
- Both vpn.mode paths render and are asserted, plus a negative test that custom
  mode without `customConfigFile` fails to render.

## [1.1.2] - 2026-07-17

### Fixed
- **Plex transcode scratch volume.** Transcode sessions previously wrote to
  Plex's default temp path on the 10Gi config PVC; concurrent 4K sessions
  could fill it and break the server's SQLite database writes. Added a
  disk-backed emptyDir at `/transcode` (`plex.transcodeScratchSize`, default
  20Gi) with a NOTES step to point each server's transcoder temp directory
  at it. Deliberately NOT memory-backed: a tmpfs emptyDir counts against the
  container's 4Gi memory limit and would invite OOMKills. Regression guards
  added (emptyDir present, sized, not tmpfs). Prompted by external QA ticket
  AKPN-009 (premise corrected: transcodes never touched the SMB share).

### Rejected external QA tickets (for the record)
- AKPN-007 (add headless service): already present since v1.0; proposed
  selector would have broken per-pod DNS.
- AKPN-008 (preStop hooks for SMB locks): configs are on block storage, not
  SMB; hook was a no-op that slows drains.
- Gluetun startupProbe on :8000/v1/health: no probes exist on gluetun to fix;
  the proposed probe targets the auth-gated control server and would
  crash-loop the pod (health endpoint is 127.0.0.1:9999).

## [1.1.1] - 2026-07-15

### Fixed
- **SABnzbd unreachable through gluetun's firewall.** gluetun drops NEW inbound
  connections on the pod interface by default, so the *arrs and kubelet probes
  could never reach SABnzbd:8080 even with a NetworkPolicy allow. Added
  `FIREWALL_INPUT_PORTS={{ sabnzbd.port }}` to the gluetun container (gluetun
  wiki, firewall.md: required for Kubernetes sidecars). Credit: external QA
  review.
- Removed stale `templates/plex-hpa.yaml`, `templates/secrets.yaml`, and
  `templates/namespace.yaml` that survived the v1.1.0 push. The orphaned HPA
  template referenced deleted values and made the chart fail to render
  entirely; the other two caused Helm ownership conflicts at install.
- ClamAV memory raised (requests 1536Mi, limits 4Gi) — the signature database
  alone needs ~1.5Gi at load; 3Gi left too little headroom for large scans.

### Added
- README: block-storage requirement for config PVCs (SQLite must not sit on
  SMB/NFS) and SABnzbd download-path guidance for atomic imports.
- NOTES: multi-replica claim-token expiry warning.
- tests/validate.py: regression guard asserting gluetun exposes
  FIREWALL_INPUT_PORTS matching the SABnzbd port.

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
