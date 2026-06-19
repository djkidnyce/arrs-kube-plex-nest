#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# install-tools.sh — Install or upgrade kubectl and helm on Linux
#
# For each tool this script:
#   1. Detects whether it is already installed and at what version
#   2. Fetches the latest available version from the official source
#   3. If an upgrade is available, prompts the user whether to install it
#   4. If not installed at all, downloads and installs automatically
#
# Architecture detection: amd64 and arm64 both supported automatically.
#
# Install location:
#   With sudo:    /usr/local/bin  (system-wide, no PATH change needed)
#   Without sudo: ~/bin           (created if needed; script adds to ~/.bashrc)
#
# Usage:
#   chmod +x install-tools.sh
#   ./install-tools.sh              # interactive
#   ./install-tools.sh --force      # always upgrade without prompting
#   ./install-tools.sh --dir ~/bin  # custom install directory
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
FORCE=false
CUSTOM_DIR=""

# ── Argument parsing ──────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force|-f)     FORCE=true; shift ;;
    --dir)          CUSTOM_DIR="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--force] [--dir /path/to/bin]"
      echo "  --force    Always upgrade to latest without prompting"
      echo "  --dir DIR  Install binaries to DIR (default: /usr/local/bin or ~/bin)"
      exit 0 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "    ${CYAN}$*${RESET}"; }
ok()      { echo -e "  ${GREEN}✓${RESET} $*"; }
warn()    { echo -e "  ${YELLOW}!${RESET} $*"; }
err()     { echo -e "  ${RED}✗${RESET} $*" >&2; exit 1; }
step()    { echo -e "\n  ${BOLD}━━  $*  ━━${RESET}\n"; }
upgrade() { echo -e "  ${MAGENTA}↑${RESET} $*"; }

# ── Detect architecture ───────────────────────────────────────────────────────
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  KUBECTL_ARCH="amd64"; HELM_ARCH="amd64" ;;
  aarch64|arm64) KUBECTL_ARCH="arm64"; HELM_ARCH="arm64" ;;
  armv7l)  KUBECTL_ARCH="arm";   HELM_ARCH="arm" ;;
  *)       warn "Unrecognised architecture: $ARCH — defaulting to amd64."; KUBECTL_ARCH="amd64"; HELM_ARCH="amd64" ;;
esac
info "Architecture: $ARCH → kubectl:$KUBECTL_ARCH  helm:$HELM_ARCH"

# ── Determine install directory ───────────────────────────────────────────────
if [[ -n "$CUSTOM_DIR" ]]; then
  INSTALL_DIR="$CUSTOM_DIR"
elif command -v sudo &>/dev/null && sudo -n true 2>/dev/null; then
  INSTALL_DIR="/usr/local/bin"
  info "sudo available — installing to $INSTALL_DIR (system-wide)."
else
  INSTALL_DIR="$HOME/bin"
  warn "No passwordless sudo — installing to $INSTALL_DIR (user only)."
  warn "If sudo is available with a password, re-run with: sudo $0"
fi

mkdir -p "$INSTALL_DIR"

# ── Add ~/bin to PATH in shell profile if needed ─────────────────────────────
add_to_path() {
  local dir="$1"
  if [[ ":$PATH:" != *":$dir:"* ]]; then
    export PATH="$dir:$PATH"
    for profile in "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile"; do
      [[ -f "$profile" ]] && echo "export PATH=\"$dir:\$PATH\"" >> "$profile" && break
    done
    ok "Added $dir to PATH (shell restart or 'source ~/.bashrc' to apply)."
  fi
}

[[ "$INSTALL_DIR" == "$HOME/bin" ]] && add_to_path "$INSTALL_DIR"

# ── Semantic version comparison ───────────────────────────────────────────────
# Returns 0 if equal, 1 if $1 > $2, 2 if $1 < $2
semver_compare() {
  local a b
  a=$(echo "${1#v}" | cut -d'+' -f1)
  b=$(echo "${2#v}" | cut -d'+' -f1)
  if [[ "$a" == "$b" ]]; then echo 0; return; fi
  local IFS=.
  read -ra va <<< "$a"
  read -ra vb <<< "$b"
  for ((i=0; i<${#va[@]}; i++)); do
    local na="${va[$i]:-0}" nb="${vb[$i]:-0}"
    if   (( na > nb )); then echo 1; return
    elif (( na < nb )); then echo 2; return
    fi
  done
  echo 0
}

# ── HTTP GET helper ───────────────────────────────────────────────────────────
http_get() {
  if command -v curl &>/dev/null; then
    curl -fsSL "$1"
  elif command -v wget &>/dev/null; then
    wget -qO- "$1"
  else
    err "Neither curl nor wget found. Install one and retry."
  fi
}

http_get_file() {
  local url="$1" dest="$2"
  info "Downloading: $url"
  if command -v curl &>/dev/null; then
    curl -fsSL -o "$dest" "$url"
  else
    wget -qO "$dest" "$url"
  fi
}

# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo -e "  ${BOLD}${CYAN}┌──────────────────────────────────────────────────┐${RESET}"
echo -e "  ${BOLD}${CYAN}│   Arrs Kube Plex Nest  ·  Tool Installer / Updater      │${RESET}"
echo -e "  ${BOLD}${CYAN}│   kubectl  +  helm  ·  No package manager       │${RESET}"
echo -e "  ${BOLD}${CYAN}└──────────────────────────────────────────────────┘${RESET}"
echo ""

# ═════════════════════════════════════════════════════════════════════════════
step "kubectl"
# ═════════════════════════════════════════════════════════════════════════════

KUBECTL_BIN="$INSTALL_DIR/kubectl"

# ── Detect installed version ──
installed_kubectl=""
kubectl_path=""
if kubectl_path=$(command -v kubectl 2>/dev/null); then
  installed_kubectl=$(kubectl version --client -o json 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['clientVersion']['gitVersion'])" 2>/dev/null \
    || kubectl version --client --short 2>/dev/null | grep -oP 'v[\d.]+' | head -1 \
    || echo "")
  [[ -n "$installed_kubectl" ]] && ok "kubectl installed  :  $installed_kubectl  ($kubectl_path)"
fi
[[ -z "$installed_kubectl" ]] && info "kubectl not found."

# ── Fetch latest stable version ──
info "Checking latest stable version from dl.k8s.io ..."
latest_kubectl=""
if latest_kubectl=$(http_get "https://dl.k8s.io/release/stable.txt" 2>/dev/null); then
  latest_kubectl="${latest_kubectl// /}"
  info "Latest available  :  $latest_kubectl"
else
  warn "Could not reach dl.k8s.io — skipping version check."
fi

# ── Decide ──
do_install_kubectl=false

if [[ -z "$installed_kubectl" ]]; then
  info "kubectl will be installed ($latest_kubectl)."
  do_install_kubectl=true
elif [[ -n "$latest_kubectl" ]]; then
  cmp=$(semver_compare "$installed_kubectl" "$latest_kubectl")
  if [[ "$cmp" == "2" ]]; then   # installed < latest
    upgrade "Upgrade available:  $installed_kubectl  →  $latest_kubectl"
    if $FORCE; then
      do_install_kubectl=true
      info "--force specified — upgrading."
    else
      read -rp "  Upgrade kubectl to $latest_kubectl? [y/N]: " ans
      [[ "$ans" =~ ^[Yy]$ ]] && do_install_kubectl=true || info "Keeping $installed_kubectl."
    fi
  elif [[ "$cmp" == "0" ]]; then
    ok "kubectl is up to date ($installed_kubectl)."
  else
    ok "kubectl is installed ($installed_kubectl) — skipping."
  fi
fi

# ── Install ──
if $do_install_kubectl; then
  target="${latest_kubectl:-v1.33.0}"
  url="https://dl.k8s.io/release/${target}/bin/linux/${KUBECTL_ARCH}/kubectl"
  info "Installing kubectl $target ..."
  http_get_file "$url" "$KUBECTL_BIN"
  chmod +x "$KUBECTL_BIN"
  ver=$("$KUBECTL_BIN" version --client --short 2>/dev/null | grep -oP 'v[\d.]+' | head -1 || echo "$target")
  ok "kubectl $ver installed to $KUBECTL_BIN"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "helm"
# ═════════════════════════════════════════════════════════════════════════════

HELM_BIN="$INSTALL_DIR/helm"

# ── Detect installed version ──
installed_helm=""
helm_path=""
if helm_path=$(command -v helm 2>/dev/null); then
  installed_helm=$(helm version --short 2>/dev/null | cut -d'+' -f1 | tr -d ' ' || echo "")
  [[ -n "$installed_helm" ]] && ok "helm installed  :  $installed_helm  ($helm_path)"
fi
[[ -z "$installed_helm" ]] && info "helm not found."

# ── Fetch latest version from GitHub API ──
info "Checking latest release from github.com/helm/helm ..."
latest_helm=""
if api_response=$(http_get "https://api.github.com/repos/helm/helm/releases/latest" 2>/dev/null); then
  latest_helm=$(echo "$api_response" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null \
    || echo "$api_response" | grep -oP '"tag_name":\s*"\K[^"]+' | head -1 || echo "")
  [[ -n "$latest_helm" ]] && info "Latest available  :  $latest_helm"
fi
if [[ -z "$latest_helm" ]]; then
  latest_helm="v4.2.1"
  warn "Could not reach GitHub API — falling back to known latest: $latest_helm"
fi

# ── Decide ──
do_install_helm=false

if [[ -z "$installed_helm" ]]; then
  info "helm will be installed ($latest_helm)."
  do_install_helm=true
elif [[ -n "$latest_helm" ]]; then
  cmp=$(semver_compare "$installed_helm" "$latest_helm")
  if [[ "$cmp" == "2" ]]; then
    upgrade "Upgrade available:  $installed_helm  →  $latest_helm"
    if $FORCE; then
      do_install_helm=true
      info "--force specified — upgrading."
    else
      read -rp "  Upgrade helm to $latest_helm? [y/N]: " ans
      [[ "$ans" =~ ^[Yy]$ ]] && do_install_helm=true || info "Keeping $installed_helm."
    fi
  elif [[ "$cmp" == "0" ]]; then
    ok "helm is up to date ($installed_helm)."
  else
    ok "helm is installed ($installed_helm) — skipping."
  fi
fi

# ── Install ──
if $do_install_helm; then
  target="${latest_helm:-v4.2.1}"
  tarball="helm-${target}-linux-${HELM_ARCH}.tar.gz"
  url="https://get.helm.sh/${tarball}"
  tmpdir=$(mktemp -d)
  trap "rm -rf $tmpdir" EXIT
  info "Installing helm $target ..."
  http_get_file "$url" "$tmpdir/$tarball"
  tar -xzf "$tmpdir/$tarball" -C "$tmpdir"
  helm_extracted=$(find "$tmpdir" -name "helm" -type f | head -1)
  [[ -z "$helm_extracted" ]] && err "helm binary not found inside tarball."
  cp "$helm_extracted" "$HELM_BIN"
  chmod +x "$HELM_BIN"
  ver=$("$HELM_BIN" version --short 2>/dev/null | cut -d'+' -f1 | tr -d ' ' || echo "$target")
  ok "helm $ver installed to $HELM_BIN"
fi

# ═════════════════════════════════════════════════════════════════════════════
step "Summary"
# ═════════════════════════════════════════════════════════════════════════════

kubectl_final=$(kubectl version --client --short 2>/dev/null | grep -oP 'v[\d.]+' | head -1 \
  || "$KUBECTL_BIN" version --client --short 2>/dev/null | grep -oP 'v[\d.]+' | head -1 \
  || echo "installed")
helm_final=$(helm version --short 2>/dev/null | cut -d'+' -f1 | tr -d ' ' \
  || "$HELM_BIN" version --short 2>/dev/null | cut -d'+' -f1 | tr -d ' ' \
  || echo "installed")

echo ""
echo -e "  ${GREEN}kubectl${RESET}  $kubectl_final"
echo -e "  ${GREEN}helm${RESET}     $helm_final"
echo ""
echo -e "  ${BOLD}Next steps:${RESET}"
echo "    1. kubectl cluster-info  (confirm it connects)"
echo "       If not configured: copy kubeconfig from your cluster"
echo "         k3s:     scp user@node:/etc/rancher/k3s/k3s.yaml ~/.kube/config"
echo "         kubeadm: scp user@node:/etc/kubernetes/admin.conf ~/.kube/config"
echo "    2. chmod 600 ~/.kube/config"
echo "    3. ./deploy.sh"
echo ""
