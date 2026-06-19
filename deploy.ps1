#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive setup and deploy script for the Arrs Kube Plex Nest Helm chart.
    Windows Server / PowerShell equivalent of deploy.sh.

.DESCRIPTION
    Steps:
      1. Verify prerequisites (helm, kubectl, cluster connectivity)
      2. Install / upgrade the SMB CSI driver in kube-system
      3. Install / upgrade metrics-server (required for Plex HPA)
      4. Prompt for all secret values (passwords hidden, never written to disk)
      5. Create Kubernetes Secrets imperatively in the target namespace
      6. Helm install / upgrade the chart
      7. Print next steps

.PARAMETER Namespace
    Kubernetes namespace to deploy into. Default: media

.PARAMETER ValuesFile
    Path to an extra values.yaml override file (optional).

.PARAMETER DryRun
    Render manifests and preview without applying anything.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -Namespace my-media
    .\deploy.ps1 -ValuesFile C:\k8s\my-values.yaml
    .\deploy.ps1 -DryRun
#>

[CmdletBinding()]
param(
    [string]$Namespace  = "media",
    [string]$ValuesFile = "",
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# ── Colour helpers ─────────────────────────────────────────────────────────────
function Write-Info    { param($m) Write-Host "  [info]  $m" -ForegroundColor Cyan }
function Write-Ok      { param($m) Write-Host "  [ok]    $m" -ForegroundColor Green }
function Write-Warn    { param($m) Write-Host "  [warn]  $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "  [error] $m" -ForegroundColor Red; exit 1 }
function Write-Banner  { param($m) Write-Host "`n━━━  $m  ━━━`n" -ForegroundColor Cyan }

# ── Helper: prompt for a hidden (password-style) value ────────────────────────
function Read-SecretValue {
    param([string]$Prompt, [string]$Default = "")
    while ($true) {
        if ($Default) {
            $display = "${Prompt} [$Default hidden]: "
        } else {
            $display = "${Prompt}: "
        }
        $secure = Read-Host $display -AsSecureString
        $plain  = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
                      [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        if ($plain) { return $plain }
        if ($Default) { return $Default }
        Write-Warn "Value cannot be empty — please try again."
    }
}

# ── Helper: prompt for a visible value ────────────────────────────────────────
function Read-PlainValue {
    param([string]$Prompt, [string]$Default = "")
    if ($Default) {
        $val = Read-Host "  ${Prompt} [$Default]"
        return if ($val) { $val } else { $Default }
    } else {
        return Read-Host "  $Prompt"
    }
}

# ── Helper: run a command and fail clearly if it errors ───────────────────────
function Invoke-Cmd {
    param([string[]]$Cmd)
    & $Cmd[0] $Cmd[1..($Cmd.Length-1)]
    if ($LASTEXITCODE -ne 0) {
        Write-Err "Command failed (exit $LASTEXITCODE): $($Cmd -join ' ')"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "1 / 6  Prerequisites"
# ─────────────────────────────────────────────────────────────────────────────

foreach ($tool in @("helm", "kubectl")) {
    $found = Get-Command $tool -ErrorAction SilentlyContinue
    if (-not $found) {
        # Also check C:\tools (default install-tools.ps1 location) in case PATH hasn't refreshed
        $altPath = Join-Path "C:\tools" "${tool}.exe"
        if (Test-Path $altPath) {
            Write-Warn "'$tool' not in PATH but found at $altPath — adding C:\tools to session PATH."
            $env:PATH = $env:PATH.TrimEnd(";") + ";C:\tools"
            $found = Get-Command $tool -ErrorAction SilentlyContinue
        }
    }
    if (-not $found) {
        Write-Host ""
        Write-Host "  '$tool' not found in PATH." -ForegroundColor Red
        Write-Host ""
        Write-Host "  Run install-tools.ps1 first (no package manager required):" -ForegroundColor Yellow
        Write-Host "    .\install-tools.ps1"
        Write-Host ""
        Write-Host "  Or download manually:"
        if ($tool -eq "kubectl") {
            Write-Host "    kubectl: https://dl.k8s.io/release/stable.txt  (get version, then)"
            Write-Host "             https://dl.k8s.io/release/<version>/bin/windows/amd64/kubectl.exe"
        } else {
            Write-Host "    helm:    https://get.helm.sh/helm-v4.2.1-windows-amd64.zip"
        }
        Write-Host ""
        exit 1
    }
    $ver = & $tool version --short 2>$null
    if (-not $ver) { $ver = & $tool version 2>$null | Select-Object -First 1 }
    Write-Ok "$tool found: $ver"
}

try {
    kubectl cluster-info 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw }
    Write-Ok "Cluster is reachable."
} catch {
    Write-Err "Cannot reach the Kubernetes cluster. Check that kubectl is configured:`n  kubectl config get-contexts"
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "2 / 6  SMB CSI Driver"
# ─────────────────────────────────────────────────────────────────────────────

$smbStatus = helm status csi-driver-smb -n kube-system 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Info "SMB CSI driver already installed — upgrading..."
    Invoke-Cmd @("helm", "upgrade", "csi-driver-smb", "csi-driver-smb/csi-driver-smb",
                 "--namespace", "kube-system", "--wait", "--timeout", "3m")
} else {
    Write-Info "Adding csi-driver-smb Helm repo..."
    helm repo add csi-driver-smb `
        "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts" 2>$null
    helm repo update 2>&1 | Out-Null

    Write-Info "Installing SMB CSI driver into kube-system..."
    Invoke-Cmd @("helm", "install", "csi-driver-smb", "csi-driver-smb/csi-driver-smb",
                 "--namespace", "kube-system", "--wait", "--timeout", "3m")
}
Write-Ok "SMB CSI driver ready."

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "3 / 6  Metrics Server (for Plex HPA)"
# ─────────────────────────────────────────────────────────────────────────────

kubectl get deployment metrics-server -n kube-system 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "metrics-server already installed."
} else {
    Write-Info "Installing metrics-server..."
    Invoke-Cmd @("kubectl", "apply", "-f",
        "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml")
    Write-Info "Waiting for metrics-server to become ready..."
    kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "metrics-server did not become ready in time — HPA may not work yet."
    } else {
        Write-Ok "metrics-server installed."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "4 / 6  Secrets collection"
# ─────────────────────────────────────────────────────────────────────────────

Write-Host "  All password prompts are hidden and values are never written to disk.`n"

Write-Host "  NAS / SMB Network" -ForegroundColor White
Write-Host "  This is the IP address or hostname of your NAS (e.g. TrueNAS) and"
Write-Host "  the name of the SMB share that holds your media library."
$NasHost = ""
while (-not $NasHost) {
    $NasHost = Read-PlainValue "NAS host IP or hostname (e.g. 192.168.1.100)"
    if (-not $NasHost) { Write-Warn "NAS host cannot be empty." }
}
$NasShare     = Read-PlainValue "SMB share name"   "media"
$NasShareSize = Read-PlainValue "Share size quota" "10Ti"
Write-Host ""

Write-Host "  TrueNAS SMB Credentials" -ForegroundColor White
$SmbUser = Read-PlainValue  "SMB username"
$SmbPass = Read-SecretValue "SMB password"

Write-Host ""
Write-Host "  Plex Claim Token" -ForegroundColor White
Write-Host "  Get one at https://plex.tv/claim — valid for 4 minutes."
Write-Host "  Leave blank to skip (claim your server manually later)."
$PlexToken = Read-Host "  Plex claim token"

Write-Host ""
Write-Host "  PrivadoVPN Credentials" -ForegroundColor White
Write-Host "  Written as a two-line openvpn.cred file (username / password)."
$VpnUser = Read-PlainValue  "PrivadoVPN username"
$VpnPass = Read-SecretValue "PrivadoVPN password"

Write-Host ""
Write-Host "  ClamAV Webhook URL" -ForegroundColor White
Write-Host "  Leave blank to disable scan alerts (can be set later)."
$ClamavWebhook = Read-Host "  Webhook URL"

Write-Host ""

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "5 / 6  Creating Secrets"
# ─────────────────────────────────────────────────────────────────────────────

if ($DryRun) {
    Write-Warn "DRY RUN — Secrets will not be created."
} else {
    # Ensure namespace exists
    kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f - | Out-Null

    # smb-credentials
    Invoke-Cmd @("kubectl", "create", "secret", "generic", "smb-credentials",
        "--from-literal=username=$SmbUser",
        "--from-literal=password=$SmbPass",
        "--namespace=$Namespace",
        "--dry-run=client", "-o", "yaml") | kubectl apply -f -
    Write-Ok "smb-credentials"

    # plex-claim (optional)
    if ($PlexToken) {
        Invoke-Cmd @("kubectl", "create", "secret", "generic", "plex-claim",
            "--from-literal=token=$PlexToken",
            "--namespace=$Namespace",
            "--dry-run=client", "-o", "yaml") | kubectl apply -f -
        Write-Ok "plex-claim"
    } else {
        Write-Warn "plex-claim skipped — create it manually before starting Plex."
    }

    # vpn-credentials — write two-line cred file to a temp path, apply, then delete
    $TempCred = [System.IO.Path]::GetTempFileName()
    try {
        # Temp file: line 1 = username, line 2 = password (OpenVPN auth-user-pass format)
        Set-Content -Path $TempCred -Value "$VpnUser`n$VpnPass" -NoNewline -Encoding UTF8
        Invoke-Cmd @("kubectl", "create", "secret", "generic", "vpn-credentials",
            "--from-file=openvpn.cred=$TempCred",
            "--namespace=$Namespace",
            "--dry-run=client", "-o", "yaml") | kubectl apply -f -
        Write-Ok "vpn-credentials"
    } finally {
        Remove-Item $TempCred -Force -ErrorAction SilentlyContinue
    }

    # clamav-notify (empty placeholder if not provided)
    $webhookArg = if ($ClamavWebhook) { $ClamavWebhook } else { "" }
    Invoke-Cmd @("kubectl", "create", "secret", "generic", "clamav-notify",
        "--from-literal=webhook-url=$webhookArg",
        "--namespace=$Namespace",
        "--dry-run=client", "-o", "yaml") | kubectl apply -f -
    if ($ClamavWebhook) {
        Write-Ok "clamav-notify"
    } else {
        Write-Warn "clamav-notify created with empty URL — scan alerts disabled."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "6 / 6  Helm install / upgrade"
# ─────────────────────────────────────────────────────────────────────────────

$HelmArgs = @(
    "upgrade", "--install", "akpn", $ScriptDir,
    "--namespace", $Namespace,
    "--create-namespace",
    "--wait",
    "--timeout", "10m",
    "--set", "nas.host=$NasHost",
    "--set", "nas.mediaShare=$NasShare",
    "--set", "nas.mediaShareSize=$NasShareSize"
)

if ($ValuesFile) {
    $HelmArgs += @("-f", $ValuesFile)
}

if ($DryRun) {
    $HelmArgs += @("--dry-run", "--debug")
    Write-Info "DRY RUN — rendering manifests only."
}

Write-Info "Running: helm $($HelmArgs -join ' ')"
& helm @HelmArgs
if ($LASTEXITCODE -ne 0) {
    Write-Err "helm upgrade --install failed (exit $LASTEXITCODE)"
}

# ─────────────────────────────────────────────────────────────────────────────
if (-not $DryRun) {
    Write-Host ""
    Write-Host "  Arrs Kube Plex Nest deployed successfully to namespace '$Namespace'" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "  1. Upload .ovpn files via filebrowser:"
    Write-Host "       kubectl port-forward svc/sabnzbd-filebrowser 8888:8888 -n $Namespace"
    Write-Host "       Then open http://localhost:8888 in your browser (default login: admin / admin)"
    Write-Host ""
    Write-Host "  2. Restart SABnzbd to apply patched .ovpn:"
    Write-Host "       kubectl rollout restart deployment/sabnzbd -n $Namespace"
    Write-Host ""
    Write-Host "  3. Get service external IPs:"
    Write-Host "       kubectl get svc -n $Namespace"
    Write-Host ""
    Write-Host "  4. Watch Plex autoscaling:"
    Write-Host "       kubectl get hpa plex-hpa -n $Namespace -w"
    Write-Host ""
}
