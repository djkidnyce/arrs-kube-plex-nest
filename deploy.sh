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

# Non-sensitive config persisted between runs (chmod 600, no passwords)
CACHE_FILE="${HOME}/.akpn-deploy.conf"

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NAMESPACE="$2"; shift 2 ;;
    -f|--values)    EXTRA_FLAGS+=("-f" "$2"); shift 2 ;;
    --dry-run)      DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: $0 [-n namespace] [-f values.yaml] [--dry-run]"
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error()   { echo -e "${RED}[error]${RESET} $*" >&2; }
fatal()   { error "$*"; exit 1; }
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
SMB_USER="${SMB_USER:-}"
VPN_USER="${VPN_USER:-}"
CLAMAV_WEBHOOK="${CLAMAV_WEBHOOK:-}"
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
  eval "$var='$value'"
}

# Visible input — shows cached value, Enter keeps it
confirm_or_prompt() {
  local var="$1" prompt="$2" current="${!1:-}" required="${3:-required}"
  if [[ -n "$current" ]]; then
    read -rp "  ${prompt} ${DIM}[${current}]${RESET}: " input
    eval "$var='${input:-$current}'"
  else
    local value=""
    while [[ -z "$value" ]]; do
      read -rp "  ${prompt}: " value
      [[ -z "$value" && "$required" == "required" ]] && warn "Cannot be empty — try again."
      [[ "$required" != "required" ]] && break
    done
    eval "$var='$value'"
  fi
}

# Password prompt — if secret already exists in cluster, offer to keep it
prompt_or_keep_password() {
  local var="$1" k8s_secret="$2" prompt="$3"
  if kubectl get secret "$k8s_secret" -n "$NAMESPACE" &>/dev/null 2>&1; then
    echo -e "  ${GREEN}Secret '$k8s_secret' already exists in '$NAMESPACE'.${RESET}"
    read -rp "  Keep existing? [Y/n]: " keep
    if [[ "${keep,,}" != "n" ]]; then
      eval "$var='__KEEP__'"
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
banner "1 / 6  Prerequisites"
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
banner "2 / 6  SMB CSI Driver"
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
banner "3 / 6  Metrics Server (for Plex HPA)"
# ─────────────────────────────────────────────────────────────────────────────

if kubectl get deployment metrics-server -n kube-system &>/dev/null 2>&1; then
  success "metrics-server already installed."
else
  info "Installing metrics-server (async — HPA will show <unknown> until it's ready)..."
  kubectl apply -f \
    https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml \
    2>/dev/null || warn "metrics-server apply failed — HPA won't function until fixed."
fi

# ─────────────────────────────────────────────────────────────────────────────
banner "4 / 6  Configuration"
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

# ── Plex claim ───────────────────────────────────────────────────────────────
echo -e "  ${BOLD}Plex Claim Token${RESET}"
echo "  Get one at https://plex.tv/claim — valid 4 minutes."
echo "  Leave blank to skip (claim manually later via: kubectl edit secret plex-claim -n ${NAMESPACE})."
if kubectl get secret plex-claim -n "$NAMESPACE" &>/dev/null 2>&1; then
  echo -e "  ${GREEN}plex-claim already exists — leaving blank keeps the existing token.${RESET}"
fi
read -rp "  Plex claim token: " PLEX_TOKEN
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

# Save non-sensitive values for next run
save_cache

# ─────────────────────────────────────────────────────────────────────────────
banner "5 / 6  Creating Secrets"
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

  # Plex claim (optional)
  if [[ -n "${PLEX_TOKEN:-}" ]]; then
    kubectl create secret generic plex-claim \
      --from-literal=token="$PLEX_TOKEN" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f - \
      && success "plex-claim updated." \
      || warn "plex-claim create failed — continuing."
  else
    if ! kubectl get secret plex-claim -n "$NAMESPACE" &>/dev/null 2>&1; then
      warn "plex-claim skipped — create it before Plex can claim your server."
    else
      info "plex-claim — keeping existing secret."
    fi
  fi

  # VPN credentials (two-line openvpn.cred file)
  if [[ "${VPN_PASS:-}" == "__KEEP__" ]]; then
    info "vpn-credentials — keeping existing secret."
  else
    CRED_FILE="$(mktemp)"
    trap "rm -f '$CRED_FILE'" EXIT
    printf '%s\n%s\n' "$VPN_USER" "$VPN_PASS" > "$CRED_FILE"
    kubectl create secret generic vpn-credentials \
      --from-file=openvpn.cred="$CRED_FILE" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f - \
      && success "vpn-credentials updated." \
      || warn "vpn-credentials create failed — continuing."
    rm -f "$CRED_FILE"
    trap - EXIT
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
banner "6 / 6  Helm install / upgrade"
# ─────────────────────────────────────────────────────────────────────────────

HELM_CMD=(
  helm upgrade --install "$RELEASE" "$CHART_DIR"
  --namespace "$NAMESPACE"
  --create-namespace
  --set "nas.host=${NAS_HOST}"
  --set "nas.mediaShare=${NAS_SHARE}"
  --set "nas.mediaShareSize=${NAS_SHARE_SIZE}"
  "${EXTRA_FLAGS[@]}"
)

if $DRY_RUN; then
  HELM_CMD+=(--dry-run --debug)
  info "DRY RUN — rendering manifests only:"
else
  # --rollback-on-failure replaces --atomic in Helm v4
  HELM_CMD+=(--rollback-on-failure --timeout 5m)
fi

info "Running: ${HELM_CMD[*]}"

if "${HELM_CMD[@]}"; then
  if ! $DRY_RUN; then
    echo
    echo -e "${GREEN}${BOLD}✓ Helm deploy complete — namespace '${NAMESPACE}'${RESET}"
    echo
    show_namespace_status
    echo -e "  ${BOLD}Next steps:${RESET}"
    echo "  1. Upload .ovpn file via filebrowser:"
    echo "       kubectl port-forward svc/sabnzbd-filebrowser 8888:8888 -n $NAMESPACE"
    echo "       → open http://localhost:8888  (login: admin / admin — change it!)"
    echo "  2. Restart SABnzbd after .ovpn upload:"
    echo "       kubectl rollout restart deployment/sabnzbd -n $NAMESPACE"
    echo "  3. Get service IPs:"
    echo "       kubectl get svc -n $NAMESPACE"
    echo "  4. Watch Plex autoscaling:"
    echo "       kubectl get hpa plex-hpa -n $NAMESPACE -w"
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
