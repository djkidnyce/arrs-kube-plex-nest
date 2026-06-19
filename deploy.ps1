#Requires -Version 5.1
<#
.SYNOPSIS
    Interactive setup and deploy script for the Arrs Kube Plex Nest Helm chart.

.DESCRIPTION
    Prompts for credentials, creates Kubernetes Secrets, and runs helm upgrade --install.
    Non-sensitive config is cached in $HOME\.akpn-deploy.conf between runs.
    Passwords are never stored — if a K8s secret already exists you can keep it.

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

$ErrorActionPreference = "Continue"   # don't die on non-terminating errors
$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$CacheFile   = Join-Path $HOME ".akpn-deploy.conf"
$Release     = "akpn"

# ── Colour helpers ─────────────────────────────────────────────────────────────
function Write-Info   { param($m) Write-Host "  [info]  $m" -ForegroundColor Cyan }
function Write-Ok     { param($m) Write-Host "  [ok]    $m" -ForegroundColor Green }
function Write-Warn   { param($m) Write-Host "  [warn]  $m" -ForegroundColor Yellow }
function Write-Err    { param($m) Write-Host "  [error] $m" -ForegroundColor Red }
function Write-Banner { param($m) Write-Host "`n━━━  $m  ━━━`n" -ForegroundColor Cyan }

function Fatal { param($m) Write-Err $m; exit 1 }

# ── Config cache ───────────────────────────────────────────────────────────────
$Cache = @{
    NAS_HOST       = ""
    NAS_SHARE      = "media"
    NAS_SHARE_SIZE = "10Ti"
    SMB_USER       = ""
    VPN_USER       = ""
    CLAMAV_WEBHOOK = ""
}

function Load-Cache {
    if (Test-Path $CacheFile) {
        Get-Content $CacheFile | ForEach-Object {
            if ($_ -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $val = $matches[2].Trim().Trim('"')
                if ($Cache.ContainsKey($key)) { $Cache[$key] = $val }
            }
        }
    }
}

function Save-Cache {
    $lines = $Cache.GetEnumerator() | Sort-Object Name | ForEach-Object {
        "$($_.Key)=`"$($_.Value)`""
    }
    $lines | Set-Content -Path $CacheFile -Encoding UTF8
    # Restrict permissions on Windows (best-effort)
    $acl = Get-Acl $CacheFile
    $acl.SetAccessRuleProtection($true, $false)
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $env:USERNAME, "FullControl", "Allow")
    $acl.AddAccessRule($rule)
    try { Set-Acl $CacheFile $acl } catch { }
    Write-Ok "Config saved to $CacheFile (re-runs will pre-fill these values)"
}

# ── Prompt helpers ─────────────────────────────────────────────────────────────

# Visible prompt — shows cached value, Enter keeps it
function Read-OrKeep {
    param([string]$Prompt, [string]$Current = "", [string]$Fallback = "")
    $display = if ($Current) { $Current } else { $Fallback }
    if ($display) {
        $input = Read-Host "  $Prompt [$display]"
        return if ($input) { $input } else { $display }
    } else {
        $val = ""
        while (-not $val) {
            $val = Read-Host "  $Prompt"
            if (-not $val) { Write-Warn "Cannot be empty." }
        }
        return $val
    }
}

# Hidden password — if K8s secret already exists, offer to keep it
function Read-PasswordOrKeep {
    param([string]$Prompt, [string]$SecretName)
    $exists = kubectl get secret $SecretName -n $Namespace 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "  Secret '$SecretName' already exists in '$Namespace'." -ForegroundColor Green
        $keep = Read-Host "  Keep existing? [Y/n]"
        if ($keep -ne "n" -and $keep -ne "N") { return "__KEEP__" }
    }
    $secure = Read-Host "  $Prompt" -AsSecureString
    return [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
               [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
}

# ── Diagnostics ────────────────────────────────────────────────────────────────
function Show-NamespaceStatus {
    Write-Host "`nNamespace '$Namespace' — current state:" -ForegroundColor White
    kubectl get all,pvc,secret -n $Namespace 2>$null
    Write-Host "`nRecent warning events:" -ForegroundColor White
    kubectl get events -n $Namespace --field-selector type=Warning `
        --sort-by='.lastTimestamp' 2>$null | Select-Object -Last 20
}

# ── Path bootstrap ─────────────────────────────────────────────────────────────
if ($env:PATH -notmatch 'C:\\tools') {
    $env:PATH = $env:PATH.TrimEnd(";") + ";C:\tools"
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "1 / 6  Prerequisites"
# ─────────────────────────────────────────────────────────────────────────────

# Auto-install kubectl and helm if missing
$ToolsScript = Join-Path $ScriptDir "install-tools.ps1"
$NeedsInstall = $false
foreach ($tool in @("helm", "kubectl")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { $NeedsInstall = $true }
}

if ($NeedsInstall) {
    if (Test-Path $ToolsScript) {
        Write-Info "kubectl or helm not found — running install-tools.ps1 automatically..."
        & powershell -ExecutionPolicy Bypass -File $ToolsScript -Force
        # Refresh PATH for this session
        $env:PATH = [System.Environment]::GetEnvironmentVariable("PATH", "Machine") + ";" +
                    [System.Environment]::GetEnvironmentVariable("PATH", "User")
    } else {
        Fatal "kubectl or helm not found and install-tools.ps1 is missing. Download the full package and try again."
    }
}

foreach ($tool in @("helm", "kubectl")) {
    $cmd = Get-Command $tool -ErrorAction SilentlyContinue
    if (-not $cmd) { Fatal "'$tool' still not found after install attempt. Check install-tools.ps1 output above." }
    $ver = & $tool version --short 2>$null
    if (-not $ver) { $ver = & $tool version 2>$null | Select-Object -First 1 }
    Write-Ok "$tool found: $ver"
}

kubectl cluster-info 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) { Fatal "Cannot reach cluster. Check: kubectl config get-contexts" }
Write-Ok "Cluster is reachable."

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "2 / 6  SMB CSI Driver"
# ─────────────────────────────────────────────────────────────────────────────
# No --wait — CSI driver runs async. PVCs bind once it's ready, not before.

helm status csi-driver-smb -n kube-system 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Info "SMB CSI driver already installed — skipping."
} else {
    Write-Info "Adding csi-driver-smb Helm repo..."
    helm repo add csi-driver-smb `
        "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-smb/master/charts" 2>$null
    helm repo update 2>$null | Out-Null

    Write-Info "Installing SMB CSI driver (async — no --wait)..."
    helm install csi-driver-smb csi-driver-smb/csi-driver-smb --namespace kube-system
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "CSI driver install returned non-zero. PVCs may be Pending until recovered."
        Write-Warn "Check: kubectl get pods -n kube-system -l app=csi-smb-node"
    } else {
        Write-Ok "SMB CSI driver installed."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "3 / 6  Metrics Server (for Plex HPA)"
# ─────────────────────────────────────────────────────────────────────────────

kubectl get deployment metrics-server -n kube-system 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "metrics-server already installed."
} else {
    Write-Info "Installing metrics-server (async — HPA shows <unknown> until ready)..."
    kubectl apply -f "https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml" 2>$null
    if ($LASTEXITCODE -ne 0) { Write-Warn "metrics-server apply failed — HPA won't function until fixed." }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "4 / 6  Configuration"
# ─────────────────────────────────────────────────────────────────────────────

Load-Cache

Write-Host "  Cached values shown in [brackets] — press Enter to keep, or type a new value." -ForegroundColor DarkGray
Write-Host "  Passwords are never cached and must be entered each run.`n" -ForegroundColor DarkGray

# Ensure namespace exists so we can check for existing secrets
if (-not $DryRun) {
    kubectl create namespace $Namespace --dry-run=client -o yaml 2>$null | kubectl apply -f - 2>$null | Out-Null
}

# ── NAS / SMB ─────────────────────────────────────────────────────────────────
Write-Host "  NAS / SMB Network" -ForegroundColor White
$Cache["NAS_HOST"]       = Read-OrKeep "NAS host IP or hostname" $Cache["NAS_HOST"]
$Cache["NAS_SHARE"]      = Read-OrKeep "SMB share name"          $Cache["NAS_SHARE"]      "media"
$Cache["NAS_SHARE_SIZE"] = Read-OrKeep "Share size quota"        $Cache["NAS_SHARE_SIZE"] "10Ti"
Write-Host ""

# Connectivity check
try {
    $ping = Test-Connection -ComputerName $Cache["NAS_HOST"] -Count 1 -Quiet -ErrorAction SilentlyContinue
    if ($ping) { Write-Ok "NAS host $($Cache['NAS_HOST']) is reachable." }
    else { Write-Warn "Could not ping $($Cache['NAS_HOST']). If on a different subnet, this may be expected." }
} catch { }

# ── SMB credentials ───────────────────────────────────────────────────────────
Write-Host "  TrueNAS SMB Credentials" -ForegroundColor White
$Cache["SMB_USER"] = Read-OrKeep "SMB username" $Cache["SMB_USER"]
Write-Host ""
$SmbPass = Read-PasswordOrKeep "SMB password" "smb-credentials"
Write-Host ""

# ── Plex claim ────────────────────────────────────────────────────────────────
Write-Host "  Plex Claim Token" -ForegroundColor White
Write-Host "  Get one at https://plex.tv/claim — valid 4 minutes."
Write-Host "  Leave blank to skip (claim manually later)."
kubectl get secret plex-claim -n $Namespace 2>$null | Out-Null
if ($LASTEXITCODE -eq 0) { Write-Host "  plex-claim already exists — leaving blank keeps it." -ForegroundColor Green }
$PlexToken = Read-Host "  Plex claim token"
Write-Host ""

# ── VPN credentials ───────────────────────────────────────────────────────────
Write-Host "  VPN Credentials" -ForegroundColor White
$Cache["VPN_USER"] = Read-OrKeep "VPN username" $Cache["VPN_USER"]
Write-Host ""
$VpnPass = Read-PasswordOrKeep "VPN password" "vpn-credentials"
Write-Host ""

# ── ClamAV webhook ────────────────────────────────────────────────────────────
Write-Host "  ClamAV Webhook URL" -ForegroundColor White
Write-Host "  Leave blank to disable scan alerts."
$Cache["CLAMAV_WEBHOOK"] = Read-OrKeep "Webhook URL" $Cache["CLAMAV_WEBHOOK"] ""
Write-Host ""

# Save non-sensitive values
Save-Cache

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "5 / 6  Creating Secrets"
# ─────────────────────────────────────────────────────────────────────────────

if ($DryRun) {
    Write-Warn "DRY RUN — Secrets will not be created."
} else {

    # smb-credentials
    if ($SmbPass -eq "__KEEP__") {
        Write-Info "smb-credentials — keeping existing secret."
    } else {
        kubectl create secret generic smb-credentials `
            "--from-literal=username=$($Cache['SMB_USER'])" `
            "--from-literal=password=$SmbPass" `
            "--namespace=$Namespace" `
            "--dry-run=client" "-o" "yaml" 2>$null | kubectl apply -f - 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "smb-credentials updated." }
        else { Write-Warn "smb-credentials create failed — continuing." }
    }

    # plex-claim (optional)
    if ($PlexToken) {
        kubectl create secret generic plex-claim `
            "--from-literal=token=$PlexToken" `
            "--namespace=$Namespace" `
            "--dry-run=client" "-o" "yaml" 2>$null | kubectl apply -f - 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { Write-Ok "plex-claim updated." }
        else { Write-Warn "plex-claim create failed — continuing." }
    } else {
        kubectl get secret plex-claim -n $Namespace 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) { Write-Warn "plex-claim skipped — Plex won't auto-claim." }
        else { Write-Info "plex-claim — keeping existing secret." }
    }

    # vpn-credentials (two-line openvpn.cred)
    if ($VpnPass -eq "__KEEP__") {
        Write-Info "vpn-credentials — keeping existing secret."
    } else {
        $TempCred = [System.IO.Path]::GetTempFileName()
        try {
            "$($Cache['VPN_USER'])`n$VpnPass" | Set-Content -Path $TempCred -NoNewline -Encoding UTF8
            kubectl create secret generic vpn-credentials `
                "--from-file=openvpn.cred=$TempCred" `
                "--namespace=$Namespace" `
                "--dry-run=client" "-o" "yaml" 2>$null | kubectl apply -f - 2>$null | Out-Null
            if ($LASTEXITCODE -eq 0) { Write-Ok "vpn-credentials updated." }
            else { Write-Warn "vpn-credentials create failed — continuing." }
        } finally {
            Remove-Item $TempCred -Force -ErrorAction SilentlyContinue
        }
    }

    # clamav-notify (always upsert)
    $webhookVal = $Cache["CLAMAV_WEBHOOK"]
    kubectl create secret generic clamav-notify `
        "--from-literal=webhook-url=$webhookVal" `
        "--namespace=$Namespace" `
        "--dry-run=client" "-o" "yaml" 2>$null | kubectl apply -f - 2>$null | Out-Null
    if ($webhookVal) { Write-Ok "clamav-notify updated." }
    else { Write-Info "clamav-notify — alerts disabled (no URL)." }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Banner "6 / 6  Helm install / upgrade"
# ─────────────────────────────────────────────────────────────────────────────

$HelmArgs = @(
    "upgrade", "--install", $Release, $ScriptDir,
    "--namespace", $Namespace,
    "--create-namespace",
    "--set", "nas.host=$($Cache['NAS_HOST'])",
    "--set", "nas.mediaShare=$($Cache['NAS_SHARE'])",
    "--set", "nas.mediaShareSize=$($Cache['NAS_SHARE_SIZE'])"
)

if ($ValuesFile) { $HelmArgs += @("-f", $ValuesFile) }

if ($DryRun) {
    $HelmArgs += @("--dry-run", "--debug")
    Write-Info "DRY RUN — rendering manifests only."
} else {
    # --rollback-on-failure replaces --atomic in Helm v4
    $HelmArgs += @("--rollback-on-failure", "--timeout", "5m")
}

Write-Info "Running: helm $($HelmArgs -join ' ')"
& helm @HelmArgs
$helmExit = $LASTEXITCODE

if ($helmExit -eq 0 -and -not $DryRun) {
    Write-Host ""
    Write-Host "  ✓ Arrs Kube Plex Nest deployed to namespace '$Namespace'" -ForegroundColor Green
    Write-Host ""
    Show-NamespaceStatus
    Write-Host "  Next steps:" -ForegroundColor White
    Write-Host "  1. Upload .ovpn file via filebrowser:"
    Write-Host "       kubectl port-forward svc/sabnzbd-filebrowser 8888:8888 -n $Namespace"
    Write-Host "       Then open http://localhost:8888  (default login: admin / admin)"
    Write-Host "  2. Restart SABnzbd after .ovpn upload:"
    Write-Host "       kubectl rollout restart deployment/sabnzbd -n $Namespace"
    Write-Host "  3. Get service IPs: kubectl get svc -n $Namespace"
    Write-Host "  4. Watch HPA:       kubectl get hpa plex-hpa -n $Namespace -w"
} elseif ($helmExit -ne 0) {
    Write-Host ""
    Write-Err "Helm deploy failed (exit $helmExit). Current cluster state:"
    Show-NamespaceStatus
    Write-Host ""
    Write-Host "  Tips:" -ForegroundColor Yellow
    Write-Host "    PVCs Pending? → kubectl describe pvc -n $Namespace"
    Write-Host "    Pods failing? → kubectl logs <pod> -n $Namespace --previous"
    Write-Host "    CSI issue?    → kubectl get pods -n kube-system -l app=csi-smb-node"
    Write-Host "    Re-run script — cached values will be pre-filled."
    exit 1
}
