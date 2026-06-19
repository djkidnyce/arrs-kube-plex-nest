#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# deploy.sh — Interactive setup and deploy script for Arrs Kube Plex Nest Helm chart
#
# What this does (in order):
#   1. Verify prerequisites (helm, kubectl, cluster connectivity)
#   2. Install / upgrade the SMB CSI driver in kube-system
#   3. Install / upgrade metrics-server (required for Plex HPA)
#   4. Prompt for all secret values (never written to disk)
#   5. Create Kubernetes Secrets imperatively in the target namespace
#   6. Helm install / upgrade the chart
#   7. Print next steps
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh                        # install with defaults
#   ./deploy.sh -n my-namespace        # custom namespace
#   ./deploy.sh -f my-values.yaml      # extra values override file
#   ./deploy.sh --dry-run              # render manifests, don't apply
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ─────────────────────────────────────────────────────────────────
NAMESPACE="media"
RELEASE="akpn"
CHART_DIR="$(cd "$(dirname "$0")" && pwd)"
EXTRA_FLAGS=()
DRY_RUN=false

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
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error()   { echo -e "${RED}[error]${RESET} $*" >&2; exit 1; }
banner()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }

# ── Helper: prompt for a secret value ────────────────────────────────────────
# Usage: prompt_secret VARNAME "Prompt text" [default]
prompt_secret() {
  local var="$1" prompt="$2" default="${3:-}"
  local value=""
  while [[ -z "$value" ]]; do
    if [[ -n "$default" ]]; then
      read -rsp "  ${prompt} [${default}]: " value
      echo
      value="${value:-$default}"
    else
      read -rsp "  ${prompt}: " value
      echo
    fi
    [[ -z "$value" ]] && warn "Value cannot be empty — please try again."
  done
  eval "$var"='$value'
}

# ── Helper: prompt for a plain (visible) value ────────────────────────────────
prompt_plain() {
  local var="$1" prompt="$2" default="${3:-}"
  local value=""
  if [[ -n "$default" ]]; then
    read -rp "  ${prompt} [${default}]: " value
    value="${value:-$default}"
  else
    read -rp "  ${prompt}: " value
  fi
  eval "$var"='$value'
}

# ─────────────────────────────────────────────────────────────────────────────
banner "1 / 6  Prerequisites"
# ─────────────────────────────────────────────────────────────────────────────

for cmd in helm kubectl; do
  command -v "$cmd" &>/dev/null || error "'$cmd' is not installed or not in PATH."
  success "$cmd found: $($cmd version --short 2>/dev/null | head -1 || $cmd version | head -1)"
done

kubectl cluster-info &>/dev/null || error "Cannot reach the Kubernetes cluster. Is your kubeconfig set?"
success "Cluster is reachable."

# ─────────────────────────────────────────────────────────────────────────────
banner "2 / 6  SMB CSI Driver"
# ─────────────────────────────────────────────────────────────────────────────

if helm status csi-driver-smb -n kube-system &>/dev/null; then
  info "SMB CSI driver already installed — upgrading..."
  helm upgrade csi-driver-smb csi-driver-smb/csi-driver-smb \
    --namespace kube-system --wait --timeout 3m
else
  info "Adding csi-driver-smb Helm repo..."
  helm repo add csi-driver-smb \
    https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts \
    2>/dev/null || true
  helm repo update csi-driver-smb 2>/dev/null || helm repo update

  info "Installing SMB CSI driver into kube-system..."
  helm install csi-driver-smb csi-driver-smb/csi-driver-smb \
    --namespace kube-system --wait --timeout 3m
fi
success "SMB CSI driver ready."

# ─────────────────────────────────────────────────────────────────────────────
banner "3 / 6  Metrics Server (for Plex HPA)"
# ─────────────────────────────────────────────────────────────────────────────

if kubectl get deployment metrics-server -n kube-system &>/dev/null; then
  success "metrics-server already installed."
else
  info "Installing metrics-server..."
  kubectl apply -f \
    https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  info "Waiting for metrics-server to become ready..."
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s || \
    warn "metrics-server did not become ready in time — HPA may not work yet."
  success "metrics-server installed."
fi

# ─────────────────────────────────────────────────────────────────────────────
banner "4 / 6  Secrets collection"
# ─────────────────────────────────────────────────────────────────────────────

echo -e "  ${BOLD}All values are hidden and never written to disk.${RESET}"
echo

echo -e "  ${BOLD}NAS / SMB Network${RESET}"
echo "  This is the IP address or hostname of your NAS (e.g. TrueNAS) and"
echo "  the name of the SMB share that holds your media library."
while true; do
  prompt_plain NAS_HOST "NAS host IP or hostname (e.g. 192.168.1.100)"
  [[ -n "$NAS_HOST" ]] && break
  warn "NAS host cannot be empty."
done
prompt_plain NAS_SHARE      "SMB share name"       "media"
prompt_plain NAS_SHARE_SIZE "Share size quota"     "10Ti"
echo

echo -e "  ${BOLD}TrueNAS SMB Credentials${RESET}"
prompt_plain  SMB_USER     "SMB username"
prompt_secret SMB_PASS     "SMB password"

echo
echo -e "  ${BOLD}Plex Claim Token${RESET}"
echo "  Get one at https://plex.tv/claim — valid for 4 minutes."
echo "  Leave blank to skip (you can set it later with: kubectl edit secret plex-claim)"
read -rp "  Plex claim token: " PLEX_TOKEN
echo

echo -e "  ${BOLD}PrivadoVPN Credentials${RESET}"
echo "  These are written to the Secret as a two-line openvpn.cred file:"
echo "  Line 1 = username, Line 2 = password"
prompt_plain  VPN_USER  "PrivadoVPN username"
prompt_secret VPN_PASS  "PrivadoVPN password"

echo
echo -e "  ${BOLD}ClamAV Webhook URL${RESET}"
echo "  Format depends on clamav.notificationType in values.yaml."
echo "  Leave blank to skip (alerts disabled until set)."
read -rp "  Webhook URL: " CLAMAV_WEBHOOK
echo

# ─────────────────────────────────────────────────────────────────────────────
banner "5 / 6  Creating Secrets"
# ─────────────────────────────────────────────────────────────────────────────

if $DRY_RUN; then
  warn "DRY RUN — Secrets will not be created."
else
  # Create namespace first so secrets have somewhere to live
  kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

  # SMB credentials
  kubectl create secret generic smb-credentials \
    --from-literal=username="$SMB_USER" \
    --from-literal=password="$SMB_PASS" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  success "smb-credentials"

  # Plex claim (optional)
  if [[ -n "$PLEX_TOKEN" ]]; then
    kubectl create secret generic plex-claim \
      --from-literal=token="$PLEX_TOKEN" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    success "plex-claim"
  else
    warn "plex-claim skipped — create it manually before first Plex startup."
  fi

  # VPN credentials (two-line cred file)
  CRED_FILE="$(mktemp)"
  trap "rm -f $CRED_FILE" EXIT
  printf '%s\n%s\n' "$VPN_USER" "$VPN_PASS" > "$CRED_FILE"
  kubectl create secret generic vpn-credentials \
    --from-file=openvpn.cred="$CRED_FILE" \
    --namespace="$NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  rm -f "$CRED_FILE"
  success "vpn-credentials"

  # ClamAV webhook (optional)
  if [[ -n "$CLAMAV_WEBHOOK" ]]; then
    kubectl create secret generic clamav-notify \
      --from-literal=webhook-url="$CLAMAV_WEBHOOK" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    success "clamav-notify"
  else
    # Create placeholder so the chart can reference it
    kubectl create secret generic clamav-notify \
      --from-literal=webhook-url="" \
      --namespace="$NAMESPACE" \
      --dry-run=client -o yaml | kubectl apply -f -
    warn "clamav-notify created with empty URL — ClamAV alerts disabled."
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
banner "6 / 6  Helm install / upgrade"
# ─────────────────────────────────────────────────────────────────────────────

HELM_CMD=(
  helm upgrade --install "$RELEASE" "$CHART_DIR"
  --namespace "$NAMESPACE"
  --create-namespace
  --wait
  --timeout 10m
  --set "nas.host=${NAS_HOST}"
  --set "nas.mediaShare=${NAS_SHARE}"
  --set "nas.mediaShareSize=${NAS_SHARE_SIZE}"
  "${EXTRA_FLAGS[@]}"
)

if $DRY_RUN; then
  HELM_CMD+=(--dry-run --debug)
  info "DRY RUN — rendering manifests only:"
fi

info "Running: ${HELM_CMD[*]}"
"${HELM_CMD[@]}"

# ─────────────────────────────────────────────────────────────────────────────
if ! $DRY_RUN; then
  echo
  echo -e "${GREEN}${BOLD}✓ Arrs Kube Plex Nest deployed successfully to namespace '${NAMESPACE}'${RESET}"
  echo
  echo -e "  ${BOLD}Next steps:${RESET}"
  echo "  1. Upload .ovpn files via filebrowser:"
  echo "       kubectl port-forward svc/sabnzbd-filebrowser 8888:8888 -n $NAMESPACE"
  echo "       open http://localhost:8888  (default login: admin / admin)"
  echo "  2. Restart SABnzbd to apply patched .ovpn:"
  echo "       kubectl rollout restart deployment/sabnzbd -n $NAMESPACE"
  echo "  3. Get service IPs:"
  echo "       kubectl get svc -n $NAMESPACE"
  echo "  4. Check Plex HPA:"
  echo "       kubectl get hpa plex-hpa -n $NAMESPACE -w"
  echo
fi
