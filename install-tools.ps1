#Requires -Version 5.1
<#
.SYNOPSIS
    Installs or upgrades kubectl and helm on Windows Server.
    No Chocolatey, no Winget, no package manager required.

.DESCRIPTION
    For each tool this script:
      1. Detects whether it is already installed and at what version
      2. Fetches the latest available version from the official source
      3. If an upgrade is available, prompts the user whether to install it
      4. If not installed at all, downloads and installs automatically

    Sources:
      kubectl  — https://dl.k8s.io/release/stable.txt  (official Kubernetes CDN)
      helm     — https://api.github.com/repos/helm/helm/releases/latest

    Downloads go to -InstallDir (default C:\tools) and that folder is added
    to PATH. Run as Administrator for system-wide PATH; without Admin the
    current user PATH is updated instead.

.PARAMETER InstallDir
    Directory to place the binaries. Default: C:\tools

.PARAMETER Force
    Skip all prompts and always install/upgrade to the latest version.

.EXAMPLE
    # Standard interactive run (recommended):
    .\install-tools.ps1

    # Specify a custom directory:
    .\install-tools.ps1 -InstallDir "D:\k8s-tools"

    # Unattended / CI — always upgrade to latest:
    .\install-tools.ps1 -Force
#>

[CmdletBinding()]
param(
    [string]$InstallDir = "C:\tools",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ── Colour helpers ─────────────────────────────────────────────────────────────
function Write-Info    { param($m) Write-Host "    $m" -ForegroundColor Cyan }
function Write-Ok      { param($m) Write-Host "  ✓ $m" -ForegroundColor Green }
function Write-Warn    { param($m) Write-Host "  ! $m" -ForegroundColor Yellow }
function Write-Err     { param($m) Write-Host "  ✗ $m" -ForegroundColor Red }
function Write-Step    { param($m) Write-Host "`n  ━━  $m  ━━`n" -ForegroundColor White }
function Write-Upgrade { param($m) Write-Host "  ↑ $m" -ForegroundColor Magenta }

# ── Semantic version comparison ────────────────────────────────────────────────
# Returns: -1 (a < b), 0 (equal), 1 (a > b)
function Compare-SemVer {
    param([string]$a, [string]$b)
    # Strip leading 'v' and any build metadata after '+'
    $cleanA = ($a -replace '^v', '') -split '\+' | Select-Object -First 1
    $cleanB = ($b -replace '^v', '') -split '\+' | Select-Object -First 1
    try {
        $va = [Version]$cleanA
        $vb = [Version]$cleanB
        return $va.CompareTo($vb)
    } catch {
        # Fall back to string comparison if version parsing fails
        if ($cleanA -eq $cleanB) { return 0 }
        return -1
    }
}

# ── Web helper ─────────────────────────────────────────────────────────────────
function Invoke-GetString {
    param([string]$Url)
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "akpn-installer/1.0")
    return $wc.DownloadString($Url).Trim()
}

function Invoke-GetFile {
    param([string]$Url, [string]$Dest)
    Write-Info "Downloading  →  $Url"
    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "akpn-installer/1.0")
    $wc.DownloadFile($Url, $Dest)
}

# ── PATH helper ────────────────────────────────────────────────────────────────
function Add-ToPath {
    param([string]$Dir)
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
    $scope = if ($isAdmin) { "Machine" } else { "User" }
    $current = [Environment]::GetEnvironmentVariable("PATH", $scope) ?? ""
    $parts   = $current -split ";" | Where-Object { $_ }
    if ($Dir -in $parts) {
        Write-Info "$Dir already in $scope PATH."
        return
    }
    $newPath = ($parts + $Dir) -join ";"
    [Environment]::SetEnvironmentVariable("PATH", $newPath, $scope)
    $env:PATH = ($env:PATH.TrimEnd(";") + ";" + $Dir)
    Write-Ok "Added $Dir to $scope PATH."
    if ($scope -eq "User") {
        Write-Warn "User PATH updated — open a NEW PowerShell window for it to take effect."
    }
}

# ─────────────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ┌──────────────────────────────────────────────────┐" -ForegroundColor Cyan
Write-Host "  │   Arrs Kube Plex Nest  ·  Tool Installer / Updater      │" -ForegroundColor Cyan
Write-Host "  │   kubectl  +  helm  ·  No package manager       │" -ForegroundColor Cyan
Write-Host "  └──────────────────────────────────────────────────┘" -ForegroundColor Cyan
Write-Host ""

# ── Create install directory ──────────────────────────────────────────────────
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Write-Ok "Created install directory: $InstallDir"
} else {
    Write-Info "Install directory: $InstallDir"
}

# ═════════════════════════════════════════════════════════════════════════════
Write-Step "kubectl"
# ═════════════════════════════════════════════════════════════════════════════

$KubectlExe = Join-Path $InstallDir "kubectl.exe"

# ── Detect installed version ──
$installedKubectl = $null
# Check both PATH and the install dir
$kubectlCmd = Get-Command "kubectl" -ErrorAction SilentlyContinue
if (-not $kubectlCmd -and (Test-Path $KubectlExe)) {
    $kubectlCmd = Get-Command $KubectlExe -ErrorAction SilentlyContinue
}
if ($kubectlCmd) {
    try {
        $vJson = & $kubectlCmd.Source version --client -o json 2>$null | ConvertFrom-Json
        $installedKubectl = $vJson.clientVersion.gitVersion   # e.g. "v1.33.1"
        Write-Ok "kubectl installed  :  $installedKubectl  ($($kubectlCmd.Source))"
    } catch {
        Write-Warn "kubectl found but version check failed — will re-install."
    }
} else {
    Write-Info "kubectl not found."
}

# ── Fetch latest stable version ──
Write-Info "Checking latest stable version from dl.k8s.io ..."
$latestKubectl = $null
try {
    $latestKubectl = Invoke-GetString "https://dl.k8s.io/release/stable.txt"
    Write-Info "Latest available  :  $latestKubectl"
} catch {
    Write-Warn "Could not reach dl.k8s.io — skipping version check."
}

# ── Decide what to do ──
$doInstallKubectl = $false

if (-not $installedKubectl) {
    Write-Info "kubectl will be installed ($latestKubectl)."
    $doInstallKubectl = $true
} elseif ($latestKubectl -and (Compare-SemVer $installedKubectl $latestKubectl) -lt 0) {
    Write-Upgrade "Upgrade available:  $installedKubectl  →  $latestKubectl"
    if ($Force) {
        $doInstallKubectl = $true
        Write-Info "-Force specified — upgrading."
    } else {
        $ans = Read-Host "  Upgrade kubectl to $latestKubectl? [y/N]"
        $doInstallKubectl = $ans -match "^[Yy]"
        if (-not $doInstallKubectl) { Write-Info "Keeping $installedKubectl." }
    }
} elseif ($latestKubectl -and (Compare-SemVer $installedKubectl $latestKubectl) -eq 0) {
    Write-Ok "kubectl is up to date ($installedKubectl)."
} else {
    Write-Ok "kubectl is installed ($installedKubectl) — skipping."
}

# ── Download and install ──
if ($doInstallKubectl) {
    $targetVer  = if ($latestKubectl) { $latestKubectl } else { "v1.33.0" }
    $kubectlUrl = "https://dl.k8s.io/release/${targetVer}/bin/windows/amd64/kubectl.exe"
    Write-Info "Installing kubectl $targetVer ..."
    Invoke-GetFile -Url $kubectlUrl -Dest $KubectlExe
    $vJson = & $KubectlExe version --client -o json 2>$null | ConvertFrom-Json
    Write-Ok "kubectl $($vJson.clientVersion.gitVersion) installed to $KubectlExe"
}

# ═════════════════════════════════════════════════════════════════════════════
Write-Step "helm"
# ═════════════════════════════════════════════════════════════════════════════

$HelmExe = Join-Path $InstallDir "helm.exe"

# ── Detect installed version ──
$installedHelm = $null
$helmCmd = Get-Command "helm" -ErrorAction SilentlyContinue
if (-not $helmCmd -and (Test-Path $HelmExe)) {
    $helmCmd = Get-Command $HelmExe -ErrorAction SilentlyContinue
}
if ($helmCmd) {
    try {
        $raw = & $helmCmd.Source version --short 2>$null
        # "v4.2.0+gabcdef" → "v4.2.0"
        $installedHelm = ($raw -split '\+')[0].Trim()
        Write-Ok "helm installed  :  $installedHelm  ($($helmCmd.Source))"
    } catch {
        Write-Warn "helm found but version check failed — will re-install."
    }
} else {
    Write-Info "helm not found."
}

# ── Fetch latest version from GitHub API ──
Write-Info "Checking latest release from github.com/helm/helm ..."
$latestHelm = $null
try {
    $json = Invoke-GetString "https://api.github.com/repos/helm/helm/releases/latest"
    $latestHelm = ($json | ConvertFrom-Json).tag_name   # e.g. "v4.2.1"
    Write-Info "Latest available  :  $latestHelm"
} catch {
    # Fallback: known latest at time of release
    $latestHelm = "v4.2.1"
    Write-Warn "Could not reach GitHub API — falling back to known latest: $latestHelm"
}

# ── Decide what to do ──
$doInstallHelm = $false

if (-not $installedHelm) {
    Write-Info "helm will be installed ($latestHelm)."
    $doInstallHelm = $true
} elseif ($latestHelm -and (Compare-SemVer $installedHelm $latestHelm) -lt 0) {
    Write-Upgrade "Upgrade available:  $installedHelm  →  $latestHelm"
    if ($Force) {
        $doInstallHelm = $true
        Write-Info "-Force specified — upgrading."
    } else {
        $ans = Read-Host "  Upgrade helm to $latestHelm? [y/N]"
        $doInstallHelm = $ans -match "^[Yy]"
        if (-not $doInstallHelm) { Write-Info "Keeping $installedHelm." }
    }
} elseif ($latestHelm -and (Compare-SemVer $installedHelm $latestHelm) -eq 0) {
    Write-Ok "helm is up to date ($installedHelm)."
} else {
    Write-Ok "helm is installed ($installedHelm) — skipping."
}

# ── Download and install ──
if ($doInstallHelm) {
    $targetVer  = if ($latestHelm) { $latestHelm } else { "v4.2.1" }
    $helmZipUrl = "https://get.helm.sh/helm-${targetVer}-windows-amd64.zip"
    $helmZip    = Join-Path $env:TEMP "helm-${targetVer}-windows-amd64.zip"
    $helmExtDir = Join-Path $env:TEMP "helm-extract-$(Get-Random)"

    Write-Info "Installing helm $targetVer ..."
    Invoke-GetFile -Url $helmZipUrl -Dest $helmZip
    Write-Info "Extracting ..."
    Expand-Archive -Path $helmZip -DestinationPath $helmExtDir -Force
    $helmBin = Get-ChildItem -Path $helmExtDir -Recurse -Filter "helm.exe" | Select-Object -First 1
    if (-not $helmBin) { Write-Err "helm.exe not found inside ZIP."; exit 1 }
    Copy-Item -Path $helmBin.FullName -Destination $HelmExe -Force
    Remove-Item $helmZip    -Force -ErrorAction SilentlyContinue
    Remove-Item $helmExtDir -Recurse -Force -ErrorAction SilentlyContinue
    $ver = (& $HelmExe version --short 2>$null -split '\+')[0].Trim()
    Write-Ok "helm $ver installed to $HelmExe"
}

# ═════════════════════════════════════════════════════════════════════════════
Write-Step "PATH"
# ═════════════════════════════════════════════════════════════════════════════
Add-ToPath -Dir $InstallDir

# ═════════════════════════════════════════════════════════════════════════════
Write-Step "Summary"
# ═════════════════════════════════════════════════════════════════════════════

$kubectlFinal = & (Join-Path $InstallDir "kubectl.exe") version --client --short 2>$null `
                | Select-Object -First 1
$helmFinal    = (& (Join-Path $InstallDir "helm.exe") version --short 2>$null `
                -split '\+')[0].Trim()

Write-Host ""
Write-Host "  kubectl  $kubectlFinal" -ForegroundColor Green
Write-Host "  helm     $helmFinal"    -ForegroundColor Green
Write-Host ""
Write-Host "  Next steps:" -ForegroundColor White
Write-Host "    1. Open a NEW PowerShell window (PATH refresh)"
Write-Host "    2. Copy kubeconfig  →  `$env:USERPROFILE\.kube\config"
Write-Host "       (k3s: /etc/rancher/k3s/k3s.yaml on the cluster node)"
Write-Host "    3. kubectl cluster-info  (confirm it connects)"
Write-Host "    4. .\deploy.ps1"
Write-Host ""
