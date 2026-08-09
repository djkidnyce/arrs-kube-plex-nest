#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Interactive setup and deploy script for Arrs Kube Plex Nest
#
# Usage:
#   ./deploy.sh                        # install / upgrade with defaults
#   ./deploy.sh -n my-namespace        # custom namespace
#   ./deploy.sh -f my-values.yaml      # extra values override file
#   ./deploy.sh --dry-run              # render manifests, don't apply
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail   # unbound-var + pipefail, but NOT errexit (we handle errors)

# ── Defaults ─────────────────────────────────────────────────────────────────
NAMESPACE="media"
RELEASE="akpn"
CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRA_FLAGS=()
DRY_RUN=false
OVPN_DIR=""
AUTOWIRE=true
SAB_PORT=8080

# Non-sensitive config persisted between runs (chmod 600, no passwords)
CACHE_FILE="${HOME}/.akpn-deploy.conf"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -f|--values)    EXTRA_FLAGS+=("-f" "$2"); shift 2 ;;
    --ovpn-dir)     OVPN_DIR="$2"; shift 2 ;;
    --no-autowire)  AUTOWIRE=false; shift ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: $0 [-n namespace] [-f values.yaml] [--ovpn-dir /path/to/ovpns] [--no-autowire] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error()   { echo -e "${RED}[error]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }

# Print a table of externally reachable services (node IP + nodePort) plus the
# in-cluster FQDN:port, and write a gitignored Markdown copy for documentation.
print_service_endpoints() {
  local node_ip md jp
  node_ip=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
  if [ -z "$node_ip" ]; then
    warn "Could not determine node IP; skipping endpoint table."
    return 0
  fi
  jp='{range .items[?(@.spec.type=="NodePort")]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.metadata.name}{"."}{.metadata.namespace}{".svc.cluster.local"}{"\t"}{range .spec.ports[*]}{.port}{":"}{.nodePort}{" "}{end}{"\n"}{end}'
  md="service-endpoints.local.md"

  {
    printf 'SERVICE\tFQDN:PORT\tNODEPORT URL\n'
    kubectl get svc -A -o jsonpath="$jp" \
    | while IFS=$'\t' read -r svc fqdn pairs; do
        for pair in $pairs; do
          printf '%s\t%s:%s\thttp://%s:%s\n' "$svc" "$fqdn" "${pair%%:*}" "$node_ip" "${pair##*:}"
        done
      done
  } | column -t -s "$(printf '\t')"

  {
    printf '| Service | FQDN:Port | NodePort URL |\n|---|---|---|\n'
    kubectl get svc -A -o jsonpath="$jp" \
    | while IFS=$'\t' read -r svc fqdn pairs; do
        for pair in $pairs; do
          printf '| %s | `%s:%s` | [http://%s:%s](http://%s:%s) |\n' \
            "$svc" "$fqdn" "${pair%%:*}" "$node_ip" "${pair##*:}" "$node_ip" "${pair##*:}"
        done
      done
  } > "$md" 2>/dev/null && info "Documented endpoints to $md (gitignored)."
}

# Show what the cluster node(s) physically have — CPU cores and RAM — so app
# selection can be matched to capacity and avoid overcommit bottlenecks.
show_node_capacity() {
  echo -e "  ${BOLD}Cluster node capacity${RESET}"
  kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.capacity.cpu}{"\t"}{.status.allocatable.cpu}{"\t"}{.status.capacity.memory}{"\t"}{.status.allocatable.memory}{"\n"}{end}' 2>/dev/null \
  | awk -F'\t' '{ c=$4; a=$5; sub(/Ki/,"",c); sub(/Ki/,"",a);
      printf "    %s: CPU %s cores (alloc %s) | RAM %.1fGi (alloc %.1fGi)\n", $1,$2,$3, c/1048576, a/1048576 }' \
  || warn "  Could not read node capacity."
}

# After deploy, show how much of the node is committed. Requests are what the
# scheduler reserves; Limits over 100%% means the node is overcommitted and can
# throttle or OOM under simultaneous load — the bottleneck signal to watch.
show_node_allocated() {
  echo -e "  ${BOLD}Node resource commitment (requests / limits)${RESET}"
  local n
  for n in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    echo "  ${n}:"
    kubectl describe node "$n" 2>/dev/null \
      | sed -n '/Allocated resources:/,/Events:/p' \
      | grep -E '^[[:space:]]+(cpu|memory|Resource)' | sed 's/^/    /'
  done
  kubectl top nodes 2>/dev/null | sed 's/^/    /' || info "  (install metrics-server for live usage via kubectl top)"
}
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }

# ── Config cache ──────────────────────────────────────────────────────────────
load_cache() {
  [[ -f "$CACHE_FILE" ]] && source "$CACHE_FILE" 2>/dev/null || true
}

save_cache() {
  cat > "$CACHE_FILE" <<EOF
NAS_HOST="${NAS_HOST:-}"
NAS_SHARE="${NAS_SHARE:-}"
NAS_SHARE_SIZE="${NAS_SHARE_SIZE:-}"
PLEX_REPLICAS="${PLEX_REPLICAS:-}"
SMB_USER="${SMB_USER:-}"
VPN_USER="${VPN_USER:-}"
EOF
  chmod 600 "$CACHE_FILE"
  success "Config saved to ${DIM}${CACHE_FILE}${RESET} (re-runs will pre-fill these values)"
}

# ── Prompts ───────────────────────────────────────────────────────────────────
# Hidden input (passwords)
prompt_secret() {
  local var="$1" prompt="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -rsp "  ${prompt}: " value; echo
    [[ -z "$value" ]] && warn "Cannot be empty — try again."
  done
  printf -v "$var" '%s' "$value"
}

# Visible input — shows cached value, Enter keeps it
confirm_or_prompt() {
  local var="$1" prompt="$2" current="${!1:-}" required="${3:-required}"
  if [[ -n "$current" ]]; then
    read -rp "  ${prompt} ${DIM}[${current}]${RESET}: " input
    printf -v "$var" '%s' "${input:-$current}"
  else
    local value=""
    while [[ -z "$value" ]]; do
      read -rp "  ${prompt}: " value
      [[ -z "$value" && "$required" == "required" ]] && warn "Cannot be empty — try again."
      [[ "$required" != "required" ]] && break
    done
    printf -v "$var" '%s' "$value"
  fi
}

# Password prompt — if secret already exists in cluster, offer to keep it
prompt_or_keep_password() {
  local var="$1" k8s_secret="$2" prompt="$3"
  if kubectl get secret "$k8s_secret" -n "$NAMESPACE" &>/dev/null 2>&1; then
    echo -e "  ${GREEN}Secret '$k8s_secret' already exists in '$NAMESPACE'.${RESET}"
    read -rp "  Keep existing? [Y/n]: " keep
    if [[ "${keep,,}" != "n" ]]; then
      printf -v "$var" '%s' "__KEEP__"
      return
    fi
  fi
  prompt_secret "$var" "$prompt"
}

# ── Diagnostics ───────────────────────────────────────────────────────────────
show_namespace_status() {
  echo
  echo -e "${BOLD}Namespace '${NAMESPACE}' — current state:${RESET}"
  kubectl get all,pvc,secret -n "$NAMESPACE" 2>/dev/null || echo "  (nothing found)"
  echo
  echo -e "${BOLD}Recent events (warnings only):${RESET}"
  kubectl get events -n "$NAMESPACE" --field-selector type=Warning \
    --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || true
}

# ─────────────────────────────────────────────────────────────────────────────
banner "1 / 5  Prerequisites"
# ─────────────────────────────────────────────────────────────────────────────

# Auto-install kubectl and helm if missing
TOOLS_SCRIPT="$(dirname "$0")/install-tools.sh"
NEEDS_INSTALL=false
for cmd in helm kubectl; do
  command -v "$cmd" &>/dev/null || NEEDS_INSTALL=true
done

if $NEEDS_INSTALL; then
  if [[ -f "$TOOLS_SCRIPT" ]]; then
    info "kubectl or helm not found — running install-tools.sh automatically..."
    bash "$TOOLS_SCRIPT" --force
    # Re-source PATH in case tools were installed to ~/bin
    export PATH="$PATH:$HOME/bin:/usr/local/bin"
  else
    fatal "kubectl or helm not found and install-tools.sh is missing.\nDownload the full arrs-kube-plex-nest package and try again."
  fi
fi

for cmd in helm kubectl; do
  if ! command -v "$cmd" &>/dev/null; then
    fatal "'$cmd' still not found after install attempt. Check install-tools.sh output above."
  fi
  success "$cmd found: $($cmd version --short 2>/dev/null | head -1 || $cmd version | head -1)"
done

if ! kubectl cluster-info &>/dev/null 2>&1; then
  fatal "Cannot reach the Kubernetes cluster. Check your kubeconfig:\n  kubectl config get-contexts"
fi
success "Cluster is reachable."

# ─────────────────────────────────────────────────────────────────────────────
banner "2 / 5  SMB CSI Driver"
# ─────────────────────────────────────────────────────────────────────────────
# Note: no --wait here. CSI driver pods starting in the background is fine —
#       the PVCs won't be claimed until pods start, which happens after deploy.

if helm status csi-driver-smb -n kube-system &>/dev/null 2>&1; then
  info "SMB CSI driver already installed — skipping (run 'helm upgrade csi-driver-smb ...' to update)."
else
  info "Adding csi-driver-smb Helm repo..."
  helm repo add csi-driver-smb \
    https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts \
    2>/dev/null || true
  helm repo update 2>/dev/null || true

  info "Installing SMB CSI driver into kube-system (no --wait — running async)..."
  if ! helm install csi-driver-smb csi-driver-smb/csi-driver-smb \
    --namespace kube-system; then
    warn "SMB CSI driver install returned non-zero. PVCs may be Pending until it recovers."
    warn "Check with: kubectl get pods -n kube-system -l app=csi-smb-node"
  else
    success "SMB CSI driver installed."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
banner "3 / 5  Configuration"
# ─────────────────────────────────────────────────────────────────────────────

load_cache

echo -e "  ${DIM}Cached values shown in [brackets] — press Enter to keep, or type a new value.${RESET}"
echo -e "  ${DIM}Passwords are never cached and must be entered each run.${RESET}"
echo

# Ensure namespace exists so we can check for existing secrets below
if ! $DRY_RUN; then
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
fi

# ── NAS / SMB ─────────────────────────────────────────────────────────────────
echo -e "  ${BOLD}NAS / SMB Network${RESET}"
confirm_or_prompt NAS_HOST      "NAS host IP or hostname"  required
confirm_or_prompt NAS_SHARE     "SMB share name"           optional
NAS_SHARE="${NAS_SHARE:-media}"
confirm_or_prompt NAS_SHARE_SIZE "Share size quota"        optional
NAS_SHARE_SIZE="${NAS_SHARE_SIZE:-10Ti}"
# Normalize common shorthand (30tb, 30TB, 30t) to Kubernetes quantities (30Ti)
normalize_size() {
  local raw="${1//[[:space:]]/}" num unit
  num="${raw%%[!0-9.]*}"; unit="${raw#"$num"}"
  [[ -z "$num" ]] && { printf '%s' "$raw"; return; }
  case "${unit,,}" in
    ti|t|tb|tib) printf '%sTi' "$num" ;;
    gi|g|gb|gib) printf '%sGi' "$num" ;;
    pi|p|pb|pib) printf '%sPi' "$num" ;;
    mi|m|mb|mib) printf '%sMi' "$num" ;;
    "")          printf '%sTi' "$num" ;;
    *)           printf '%s' "$raw" ;;
  esac
}
_normalized="$(normalize_size "$NAS_SHARE_SIZE")"
if [[ "$_normalized" != "$NAS_SHARE_SIZE" ]]; then
  info "Interpreting share size '${NAS_SHARE_SIZE}' as '${_normalized}'."
  NAS_SHARE_SIZE="$_normalized"
fi
echo

# Connectivity check (ping, not SMB — just confirms NAS is reachable on the network)
if ping -c1 -W1 "$NAS_HOST" &>/dev/null 2>&1; then
  success "NAS host ${NAS_HOST} is reachable."
else
  warn "Could not ping ${NAS_HOST}. If it's on a different subnet, this is expected."
  warn "The deploy will continue — PVCs will show Pending if SMB can't connect."
fi

# ── SMB credentials ──────────────────────────────────────────────────────────
echo -e "  ${BOLD}TrueNAS SMB Credentials${RESET}"
confirm_or_prompt SMB_USER "SMB username"
echo

prompt_or_keep_password SMB_PASS "smb-credentials" "SMB password"
echo

# ── Plex servers ─────────────────────────────────────────────────────────────
echo -e "  ${BOLD}Plex${RESET}"
echo "  Plex cannot cluster, so each server is INDEPENDENT: its own config,"
echo "  its own claim token, its own port (32400, 32401, ...). All of them"
echo "  serve the same media share."
confirm_or_prompt PLEX_REPLICAS "How many Plex servers" optional
PLEX_REPLICAS="${PLEX_REPLICAS:-2}"
if ! [[ "$PLEX_REPLICAS" =~ ^[0-9]+$ ]] || [[ "$PLEX_REPLICAS" -lt 1 ]]; then
  warn "Invalid count '${PLEX_REPLICAS}' — using 2."
  PLEX_REPLICAS=2
fi
echo

# ── VPN credentials ──────────────────────────────────────────────────────────
echo -e "  ${BOLD}VPN Credentials${RESET}"
confirm_or_prompt VPN_USER "VPN username"
echo

prompt_or_keep_password VPN_PASS "vpn-credentials" "VPN password"
echo

# ── ClamAV webhook ───────────────────────────────────────────────────────────
echo -e "  ${BOLD}ClamAV Webhook URL${RESET}"
echo "  Leave blank to disable scan alerts."
confirm_or_prompt CLAMAV_WEBHOOK "Webhook URL" optional
echo

show_node_capacity
echo

# ── Application selection ─────────────────────────────────────────────────────
# Plex and SABnzbd are always installed. Pick the rest in ONE prompt; the
# selection is translated to --set <app>.enabled=... (overrides my-values).
echo -e "  ${BOLD}Application selection${RESET}"
APP_FLAGS=()
ALL_APPS=(sonarr radarr lidarr prowlarr seerr tautulli whisparr lazylibrarian audiobookshelf dispatcharr)
DEFAULT_APPS=(sonarr radarr lidarr prowlarr seerr tautulli)
if [[ -t 0 ]]; then
  echo "  Plex and SABnzbd are always installed. Choose the rest:"
  i=1; for a in "${ALL_APPS[@]}"; do printf "    %2d) %s\n" "$i" "$a"; i=$((i+1)); done
  echo "  Enter numbers or names (space or comma separated), 'all', or 'none'."
  read -rp "  Selection [Enter = ${DEFAULT_APPS[*]}]: " sel
  sel="${sel//,/ }"
  selected=()
  if [[ -z "$sel" ]]; then
    selected=("${DEFAULT_APPS[@]}")
  elif [[ "$sel" == "all" ]]; then
    selected=("${ALL_APPS[@]}")
  elif [[ "$sel" == "none" ]]; then
    selected=()
  else
    for tok in $sel; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#ALL_APPS[@]} )); then
        selected+=("${ALL_APPS[$((tok-1))]}")
      else
        for a in "${ALL_APPS[@]}"; do [[ "$a" == "$tok" ]] && selected+=("$a"); done
      fi
    done
  fi
  sel_str=" ${selected[*]-} "
  for a in "${ALL_APPS[@]}"; do
    if [[ "$sel_str" == *" $a "* ]]; then
      APP_FLAGS+=(--set "${a}.enabled=true")
    else
      APP_FLAGS+=(--set "${a}.enabled=false")
    fi
  done
  if [[ ${#selected[@]} -eq 0 ]]; then echo "  Selected: none (Plex + SABnzbd only)"; else echo "  Selected: ${selected[*]}"; fi
else
  info "Non-interactive shell — skipping app picker; using my-values.yaml / chart defaults."
fi
echo

# Save non-sensitive values for next run
save_cache

# ─────────────────────────────────────────────────────────────────────────────
banner "4 / 5  Creating Secrets"
# ─────────────────────────────────────────────────────────────────────────────

if $DRY_RUN; then
  warn "DRY RUN — Secrets will not be created."
else
  # SMB credentials
  if [[ "${SMB_PASS:-}" == "__KEEP__" ]]; then
    info "smb-credentials — keeping existing secret."
  else
    kubectl create secret generic smb-credentials \
      --from-literal=username="$SMB_USER" \
      --from-literal=password="$SMB_PASS" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f - \
      && success "smb-credentials updated." \
      || warn "smb-credentials create failed — continuing."
  fi

  # VPN credentials (two-line openvpn.cred file)
  if [[ "${VPN_PASS:-}" == "__KEEP__" ]]; then
    info "vpn-credentials — keeping existing secret."
  else
    CRED_FILE="$(mktemp)"
    trap "rm -f '$CRED_FILE'" EXIT
    printf '%s\n%s\n' "$VPN_USER" "$VPN_PASS" > "$CRED_FILE"
    # OPENVPN_USER/OPENVPN_PASSWORD are what gluetun's native providers read;
    # openvpn.cred is only used by custom (.ovpn) mode. Both are written so
    # switching vpn.mode never requires re-entering credentials.
    kubectl create secret generic vpn-credentials \
      --from-literal=OPENVPN_USER="$VPN_USER" \
      --from-literal=OPENVPN_PASSWORD="$VPN_PASS" \
      --from-file=openvpn.cred="$CRED_FILE" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f - \
      && success "vpn-credentials updated." \
      || warn "vpn-credentials create failed — continuing."
    rm -f "$CRED_FILE"
    trap - EXIT
  fi

  # gluetun control-server API key (gluetun >= v3.40 requires auth)
  if kubectl get secret gluetun-control-auth -n "$NAMESPACE" &>/dev/null 2>&1; then
    info "gluetun-control-auth — keeping existing secret."
  else
    GLUETUN_KEY="$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 48)"
    AUTH_TOML="$(mktemp)"
    trap 'rm -f "$AUTH_TOML"' EXIT
    cat > "$AUTH_TOML" <<TOML
[[roles]]
name = "vpn-rotator"
routes = ["GET /v1/openvpn/status", "PUT /v1/openvpn/status"]
auth = "apikey"
apikey = "${GLUETUN_KEY}"
TOML
    kubectl create secret generic gluetun-control-auth \
      --from-file=config.toml="$AUTH_TOML" \
      --from-literal=apikey="$GLUETUN_KEY" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f - \
      && success "gluetun-control-auth created (48-char random API key)." \
      || warn "gluetun-control-auth create failed — VPN rotation will not work."
    rm -f "$AUTH_TOML"
    trap - EXIT
  fi

  # .ovpn files → vpn-ovpn-configs Secret (never stored in the repo)
  if [[ -n "$OVPN_DIR" ]]; then
    if compgen -G "$OVPN_DIR/*.ovpn" > /dev/null; then
      OVPN_ARGS=()
      for f in "$OVPN_DIR"/*.ovpn; do OVPN_ARGS+=("--from-file=$f"); done
      # Direct create/replace, NOT `--dry-run | apply`: client-side apply
      # stores the whole object in an annotation capped at 256KiB, which a
      # folder of .ovpn files blows past.
      kubectl delete secret vpn-ovpn-configs -n "$NAMESPACE" &>/dev/null 2>&1
      kubectl create secret generic vpn-ovpn-configs \
        "${OVPN_ARGS[@]}" \
        --namespace="$NAMESPACE" \
        && success "vpn-ovpn-configs updated (${#OVPN_ARGS[@]} file(s))." \
        || warn "vpn-ovpn-configs create failed (Secrets cap at ~1MiB total; use fewer .ovpn files)."
    else
      warn "No .ovpn files found in $OVPN_DIR — skipping."
    fi
  elif ! kubectl get secret vpn-ovpn-configs -n "$NAMESPACE" &>/dev/null 2>&1; then
    warn "vpn-ovpn-configs secret missing. Load your .ovpn files with:"
    warn "  $0 --ovpn-dir /path/to/ovpn/files"
  else
    info "vpn-ovpn-configs — keeping existing secret."
  fi

  # ClamAV webhook (always upsert — empty string is valid)
  webhook_val="${CLAMAV_WEBHOOK:-}"
  kubectl create secret generic clamav-notify \
    --from-literal=webhook-url="$webhook_val" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f - &>/dev/null \
    && { [[ -n "$webhook_val" ]] && success "clamav-notify updated." || info "clamav-notify — alerts disabled (no URL)."; } \
    || warn "clamav-notify create failed — continuing."
fi

# ─────────────────────────────────────────────────────────────────────────────
banner "5 / 5  Helm install / upgrade"
# ─────────────────────────────────────────────────────────────────────────────

HELM_CMD=(
  helm upgrade --install "$RELEASE" "$CHART_DIR"
  --namespace "$NAMESPACE"
  --create-namespace
  --set "nas.host=${NAS_HOST}"
  --set "nas.mediaShare=${NAS_SHARE}"
  --set "nas.mediaShareSize=${NAS_SHARE_SIZE}"
  --set "plex.replicas=${PLEX_REPLICAS}"
  "${APP_FLAGS[@]}"
  "${EXTRA_FLAGS[@]}"
)

if $DRY_RUN; then
  HELM_CMD+=(--dry-run --debug)
  info "DRY RUN — rendering manifests only:"
else
  # No --atomic / --rollback-on-failure on purpose: the ClamAV definitions PVC
  # uses WaitForFirstConsumer and stays Pending until the CronJob first fires,
  # so helm's readiness gate can never pass and would roll back a healthy
  # install. Pods converge on their own; watch with:
  #   kubectl get pods -n <ns> -w
  :
fi

info "Running: ${HELM_CMD[*]}"

if "${HELM_CMD[@]}"; then
  if ! $DRY_RUN; then
    echo
    echo -e "${GREEN}${BOLD}✓ Helm deploy complete — namespace '${NAMESPACE}'${RESET}"
    echo
    show_namespace_status
    # ── Plex claim tokens — asked LAST, one per server ────────────────────
    # Tokens are single-use and expire in ~4 minutes, so they are collected
    # after the deploy completes, and each is consumed immediately.
    banner "Claiming ${PLEX_REPLICAS} Plex server(s)"
    echo "  Each server needs its OWN token. They are single-use and expire in"
    echo "  about 4 MINUTES, so fetch each one right before you paste it."
    echo
    echo "    https://plex.tv/claim"
    echo
    echo "  Press Enter at any prompt to skip that server; you can claim it"
    echo "  later from its web UI."
    echo

    # Library definitions rendered from values.yaml into a ConfigMap.
    PLEX_LIBS="$(kubectl get configmap plex-libraries -n "$NAMESPACE" \
      -o jsonpath='{.data.libraries}' 2>/dev/null || true)"

    NODE_IP="$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | awk '{print $1}')"

    plex_wait_ready() {
      local pod="$1" tries=0
      printf '  Waiting for %s' "$pod"
      while [[ $tries -lt 60 ]]; do
        if kubectl get pod "$pod" -n "$NAMESPACE" \
             -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null | grep -q true; then
          echo " — ready."; return 0
        fi
        printf '.'; sleep 5; tries=$((tries + 1))
      done
      echo " — timed out."; return 1
    }

    plex_token_for() {
      # Read the server's own auth token from its Preferences.xml
      kubectl exec "$1" -n "$NAMESPACE" -- sh -c \
        'grep -o "PlexOnlineToken=\"[^\"]*\"" "/config/Library/Application Support/Plex Media Server/Preferences.xml" 2>/dev/null | head -1 | cut -d\" -f2' \
        2>/dev/null | tr -d '\r\n'
    }

    plex_create_libraries() {
      local pod="$1" port="$2" token="$3"
      [[ -z "$PLEX_LIBS" || -z "$token" ]] && return 0
      echo "  Creating libraries on ${pod}:"
      while IFS='|' read -r lname ltype lpath; do
        [[ -z "${lname// }" ]] && continue
        lname="$(echo "$lname" | sed 's/^ *//; s/ *$//')"
        ltype="$(echo "$ltype" | sed 's/^ *//; s/ *$//')"
        lpath="$(echo "$lpath" | sed 's/^ *//; s/ *$//')"
        case "$ltype" in
          movie) agent="tv.plex.agents.movie"; scanner="Plex Movie" ;;
          show)  agent="tv.plex.agents.series"; scanner="Plex TV Series" ;;
          artist) agent="tv.plex.agents.music"; scanner="Plex Music" ;;
          photo) agent="tv.plex.agents.photo"; scanner="Plex Photo Scanner" ;;
          *) warn "    unknown library type '${ltype}' for ${lname} — skipping"; continue ;;
        esac
        if kubectl exec "$pod" -n "$NAMESPACE" -- sh -c \
            "curl -sf -X POST 'http://127.0.0.1:32400/library/sections' \
              --data-urlencode 'name=${lname}' \
              --data-urlencode 'type=${ltype}' \
              --data-urlencode 'agent=${agent}' \
              --data-urlencode 'scanner=${scanner}' \
              --data-urlencode 'language=en-US' \
              --data-urlencode 'location=${lpath}' \
              --data-urlencode 'X-Plex-Token=${token}' -o /dev/null" 2>/dev/null; then
          success "    ${lname} (${ltype}) → ${lpath}"
        else
          warn "    ${lname} — not created (path may not exist, or it already exists)"
        fi
      done <<< "$PLEX_LIBS"
    }

    for ((i = 0; i < PLEX_REPLICAS; i++)); do
      pod="plex-${i}"
      port=$((32400 + i))
      echo -e "  ${BOLD}${pod}${RESET}  (port ${port})"
      read -rp "  Claim token for ${pod} (Enter to skip): " PLEX_TOKEN
      if [[ -z "${PLEX_TOKEN:-}" ]]; then
        info "  ${pod} — skipped; claim later at http://${NODE_IP}:${port}/web"
        echo
        continue
      fi
      if kubectl create secret generic plex-claim \
           --from-literal=token="$PLEX_TOKEN" \
           --namespace="$NAMESPACE" \
           --dry-run=client -o yaml | kubectl apply -f - &>/dev/null; then
        kubectl delete pod "$pod" -n "$NAMESPACE" &>/dev/null || true
        if plex_wait_ready "$pod"; then
          sleep 10
          tok="$(plex_token_for "$pod")"
          if [[ -n "$tok" ]]; then
            success "  ${pod} claimed."
            plex_create_libraries "$pod" "$port" "$tok"
          else
            warn "  ${pod} started but no token found — the claim may have expired."
            warn "  Claim it directly at http://${NODE_IP}:${port}/web"
          fi
        fi
      else
        warn "  ${pod} — could not write plex-claim secret."
      fi
      echo
    done

    # ── Auto-wire the *arrs to SABnzbd (and Prowlarr) ─────────────────────
    # Strictly additive and restore-safe: GET existing config first, add only
    # what is missing, never modify or delete. A restored or hand-configured
    # app keeps its own settings.
    if [[ "${AUTOWIRE:-true}" == "true" ]] && ! $DRY_RUN; then
      banner "Auto-wiring services"

      arr_apikey() {
        # Read an *arr API key from its config.xml on the config PVC.
        kubectl exec "deploy/$1" -n "$NAMESPACE" -- \
          sh -c 'sed -n "s|.*<ApiKey>\(.*\)</ApiKey>.*|\1|p" /config/config.xml' \
          2>/dev/null | tr -d "\r\n"
      }
      sab_apikey() {
        kubectl exec deploy/sabnzbd -c sabnzbd -n "$NAMESPACE" -- \
          sh -c 'sed -n "s|^api_key *= *||p" /config/sabnzbd.ini | head -1' \
          2>/dev/null | tr -d "\r\n"
      }
      SAB_KEY="$(sab_apikey)"
      if [[ -z "$SAB_KEY" ]]; then
        warn "Could not read SABnzbd API key yet — skipping auto-wire. Re-run after SABnzbd finishes first start, or wire manually."
      else
        for app in sonarr radarr lidarr whisparr; do
          kubectl get deploy "$app" -n "$NAMESPACE" &>/dev/null || continue
          # Servarr API versions differ: Sonarr/Radarr are v3, Lidarr is v1.
          case "$app" in
            sonarr)   aport=8989; cat=tv;     apiver=v3 ;;
            radarr)   aport=7878; cat=movies; apiver=v3 ;;
            lidarr)   aport=8686; cat=music;  apiver=v1 ;;
            whisparr) aport=6969; cat=xxx;    apiver=v3 ;;
          esac
          # Wait until the app has written its API key (config.xml exists).
          AKEY=""
          for _ in $(seq 1 30); do
            AKEY="$(arr_apikey "$app")"
            [[ -n "$AKEY" ]] && break
            sleep 5
          done
          if [[ -z "$AKEY" ]]; then
            warn "  ${app}: API key not available yet — skipping (wire manually or re-run)."
            continue
          fi
          # already configured? (restore-safe)
          existing=$(kubectl exec "deploy/$app" -n "$NAMESPACE" -- \
            curl -s -H "X-Api-Key: $AKEY" \
            "http://localhost:${aport}/api/${apiver}/downloadclient" 2>/dev/null || echo "")
          if echo "$existing" | grep -q '"implementation"[[:space:]]*:[[:space:]]*"Sabnzbd"'; then
            info "  ${app}: SABnzbd already configured — leaving as is."
            continue
          fi
          body=$(cat <<JSON
{"enable":true,"protocol":"usenet","priority":1,"name":"SABnzbd",
 "implementation":"Sabnzbd","configContract":"SabnzbdSettings",
 "fields":[{"name":"host","value":"sabnzbd.${NAMESPACE}.svc.cluster.local"},{"name":"port","value":${SAB_PORT:-8080}},
 {"name":"apiKey","value":"${SAB_KEY}"},{"name":"category","value":"${cat}"},
 {"name":"useSsl","value":false}]}
JSON
)
          if kubectl exec "deploy/$app" -n "$NAMESPACE" -- \
            curl -sf -X POST -H "X-Api-Key: $AKEY" -H "Content-Type: application/json" \
            "http://localhost:${aport}/api/${apiver}/downloadclient" -d "$body" -o /dev/null 2>/dev/null; then
            success "  ${app}: SABnzbd download client added."
          else
            warn "  ${app}: could not add SABnzbd automatically — wire manually (host sabnzbd.${NAMESPACE}.svc.cluster.local, port ${SAB_PORT:-8080}, SSL off)."
          fi
        done
      fi

      # ── Prowlarr → *arrs application sync (over FQDN) ─────────────────────
      if kubectl get deploy prowlarr -n "$NAMESPACE" &>/dev/null; then
        PKEY=""
        for _ in $(seq 1 30); do PKEY="$(arr_apikey prowlarr)"; [[ -n "$PKEY" ]] && break; sleep 5; done
        if [[ -z "$PKEY" ]]; then
          warn "  prowlarr: API key not ready — add apps manually in Prowlarr, Settings, Apps."
        else
          existing_apps=$(kubectl exec deploy/prowlarr -n "$NAMESPACE" -- \
            curl -s -H "X-Api-Key: $PKEY" "http://localhost:9696/api/v1/applications" 2>/dev/null || echo "")
          for app in sonarr radarr lidarr whisparr; do
            kubectl get deploy "$app" -n "$NAMESPACE" &>/dev/null || continue
            case "$app" in
              sonarr)   aport=8989; impl=Sonarr;   cats='[5000,5010,5020,5030,5040,5045,5050]' ;;
              radarr)   aport=7878; impl=Radarr;   cats='[2000,2010,2020,2030,2040,2045,2050,2060,2070,2080]' ;;
              lidarr)   aport=8686; impl=Lidarr;   cats='[3000,3010,3030,3040]' ;;
              whisparr) aport=6969; impl=Whisparr; cats='[6000,6010,6020,6030,6040,6045,6050,6060,6070]' ;;
            esac
            if echo "$existing_apps" | grep -q "\"implementation\"[[:space:]]*:[[:space:]]*\"${impl}\""; then
              info "  prowlarr: ${app} already synced — leaving as is."; continue
            fi
            AKEY="$(arr_apikey "$app")"
            [[ -z "$AKEY" ]] && { warn "  prowlarr: ${app} API key not ready — add manually."; continue; }
            pbody=$(cat <<JSON
{"name":"${impl}","syncLevel":"fullSync","implementation":"${impl}","configContract":"${impl}Settings",
 "fields":[{"name":"prowlarrUrl","value":"http://prowlarr.${NAMESPACE}.svc.cluster.local:9696"},
 {"name":"baseUrl","value":"http://${app}.${NAMESPACE}.svc.cluster.local:${aport}"},
 {"name":"apiKey","value":"${AKEY}"},
 {"name":"syncCategories","value":${cats}}]}
JSON
)
            resp=$(kubectl exec deploy/prowlarr -n "$NAMESPACE" -- \
              curl -s -w '\n%{http_code}' -X POST -H "X-Api-Key: $PKEY" -H "Content-Type: application/json" \
              "http://localhost:9696/api/v1/applications" -d "$pbody" 2>/dev/null)
            code="${resp##*$'\n'}"; rbody="${resp%$'\n'*}"
            if [[ "$code" == 20* ]]; then
              success "  prowlarr: ${app} synced (FQDN)."
            elif printf '%s' "$rbody" | grep -q "Should be unique"; then
              info "  prowlarr: ${app} already synced — leaving as is."
            else
              warn "  prowlarr: could not sync ${app} (HTTP ${code:-?}) — add in Prowlarr, Settings, Apps (Server http://${app}.${NAMESPACE}.svc.cluster.local:${aport})."
            fi
          done
        fi
      fi

      # ── Seerr + Tautulli need a one-time Plex sign-in in their web UI, which
      #    cannot be scripted. Print the exact FQDN values to enter. ──────────
      if kubectl get deploy seerr -n "$NAMESPACE" &>/dev/null; then
        echo -e "  ${YELLOW}Finish Seerr in its web UI (one-time Plex sign-in), then add:${RESET}"
        echo "    Sonarr: http://sonarr.${NAMESPACE}.svc.cluster.local:8989  (API key from Sonarr)"
        echo "    Radarr: http://radarr.${NAMESPACE}.svc.cluster.local:7878  (API key from Radarr)"
        echo "    Plex:   plex-0.plex-headless.${NAMESPACE}.svc.cluster.local  port 32400  SSL off"
      fi
      if kubectl get deploy tautulli -n "$NAMESPACE" &>/dev/null; then
        echo -e "  ${YELLOW}Finish Tautulli in its web UI (one-time Plex sign-in):${RESET}"
        echo "    Plex:   plex-0.plex-headless.${NAMESPACE}.svc.cluster.local  port 32400  SSL off"
      fi
    fi

    echo
    echo -e "  ${BOLD}Service endpoints (NodePort):${RESET}"
    print_service_endpoints
    echo
    show_node_allocated
    echo
    echo -e "  ${BOLD}Next steps:${RESET}"
    echo "  1. Watch pods settle:"
    echo "       kubectl get pods -n $NAMESPACE -w"
    echo "  2. Service URLs and everything else:"
    echo "       helm get notes akpn -n $NAMESPACE"
    echo "  3. On each Plex server, set Settings → Transcoder → temporary"
    echo "     directory to /transcode."
  fi
else
  echo
  error "Helm deploy failed or timed out. Showing current cluster state:"
  show_namespace_status
  echo -e "  ${YELLOW}Tip:${RESET} If PVCs are Pending, check:"
  echo "    kubectl describe pvc -n $NAMESPACE"
  echo "    kubectl get pods -n kube-system -l app=csi-smb-node"
  echo
  echo -e "  ${YELLOW}Tip:${RESET} If pods are CrashLoopBackOff:"
  echo "    kubectl logs <pod-name> -n $NAMESPACE --previous"
  echo
  echo -e "  ${YELLOW}Tip:${RESET} Re-run this script — cached values will be pre-filled."
  exit 1
fi
