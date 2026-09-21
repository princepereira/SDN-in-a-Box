# ============================================================
#  Remove-VfpPod.ps1 : stop + delete pod sandboxes created by New-VfpPod.ps1
#  Run in an ELEVATED PowerShell session INSIDE the L1 Windows guest.
#
#  What it does:
#    1. Resolve the target pod sandbox(es) with crictl (by name, or all).
#    2. Stop + force-remove each sandbox (crictl stopp / rmp -f). Removing the
#       sandbox runs CNI DEL, which deletes the HNS endpoint + its VFP rules.
#    3. Prune any leftover HNS endpoints belonging to the removed sandboxes
#       (endpoint name is "<sandboxId>_<network>").
#    4. Clean up the per-pod working directories New-VfpPod.ps1 created.
#
#  Usage:
#    .\Remove-VfpPod.ps1 sender                 # remove the "sender" pod
#    .\Remove-VfpPod.ps1 -Name listener
#    .\Remove-VfpPod.ps1 -All                   # remove every pod sandbox
#    .\Remove-VfpPod.ps1 -All -PruneEndpoints   # also prune ALL dangling HNS endpoints
# ============================================================

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    # Pod sandbox name to remove (e.g. "sender", "listener"). Positional.
    [Parameter(Mandatory = $false, Position = 0, ParameterSetName = 'ByName')]
    [Alias('Name')]
    [string]$PodName,

    # Remove every pod sandbox known to crictl.
    [Parameter(Mandatory = $true, ParameterSetName = 'All')]
    [switch]$All,

    # Also remove HNS endpoints left behind (dangling). With -All this prunes
    # every HNS endpoint; by name it only prunes endpoints of removed sandboxes.
    [Parameter(Mandatory = $false)]
    [switch]$PruneEndpoints
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------
#  Static config (match New-VfpPod.ps1 / Install-ContainerdHnsVfp.ps1)
# ------------------------------------------------------------
$ContainerdRoot = 'C:\Program Files\containerd'
$ToolsBinDir    = 'C:\Tools\bin'
$DownloadDir    = Join-Path $env:TEMP 'containerd-setup'
$CrictlExe      = Join-Path $ToolsBinDir 'crictl.exe'

function Write-Section {
    param([string]$Text)
    Write-Host ""
    Write-Host "==== $Text ====" -ForegroundColor Cyan
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Import-HnsModule {
    if (Get-Command Get-HnsEndpoint -ErrorAction SilentlyContinue) { return $true }
    foreach ($m in @((Join-Path $DownloadDir 'hns.psm1'), 'C:\k\hns.psm1', (Join-Path $ToolsBinDir 'hns.psm1'))) {
        if (Test-Path $m) { Import-Module $m -Force -DisableNameChecking; break }
    }
    return [bool](Get-Command Get-HnsEndpoint -ErrorAction SilentlyContinue)
}

# ------------------------------------------------------------
#  Main
# ------------------------------------------------------------
if (-not (Test-IsAdmin)) { throw "This script must run in an ELEVATED PowerShell session." }
if (-not (Test-Path $CrictlExe)) { throw "crictl not found at $CrictlExe. Nothing to clean up." }

if ($PSCmdlet.ParameterSetName -eq 'ByName' -and -not $PodName) {
    throw "Specify a pod name (e.g. .\Remove-VfpPod.ps1 sender) or use -All."
}

$target = if ($All) { 'ALL pods' } else { "pod '$PodName'" }
Write-Section "Resolving $target"

# crictl can filter by pod name and emit just IDs (-q).
$ids = if ($All) {
    @(& $CrictlExe pods -q 2>$null)
}
else {
    @(& $CrictlExe pods --name $PodName -q 2>$null)
}
$ids = @($ids | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

if (-not $ids.Count) {
    Write-Host "  No matching pod sandboxes found." -ForegroundColor Yellow
}
else {
    Write-Host "  Found $($ids.Count) sandbox(es):"
    $ids | ForEach-Object { Write-Host "    $_" }

    Write-Section "Stopping + removing sandboxes"
    foreach ($id in $ids) {
        Write-Host "  Stopping $id ..."
        & $CrictlExe stopp $id 2>&1 | ForEach-Object { Write-Host "    $_" }
        Write-Host "  Removing $id ..."
        & $CrictlExe rmp -f $id 2>&1 | ForEach-Object { Write-Host "    $_" }
    }
}

# ------------------------------------------------------------
#  Prune leftover HNS endpoints (CNI DEL normally handles this, but a
#  force-removed / crashed sandbox can leak an endpoint).
# ------------------------------------------------------------
if ($PruneEndpoints) {
    Write-Section "Pruning HNS endpoints"
    if (Import-HnsModule) {
        $eps = @(Get-HnsEndpoint -ErrorAction SilentlyContinue)
        $toRemove = @(if ($All) {
            $eps
        }
        else {
            # Endpoint name is "<sandboxId>_<network>"; match the removed IDs.
            @($eps | Where-Object { $e = $_; $ids | Where-Object { $e.Name -like "$_*" } })
        })
        if (-not @($toRemove).Count) {
            Write-Host "  No HNS endpoints to prune."
        }
        else {
            foreach ($ep in $toRemove) {
                Write-Host "  Removing HNS endpoint '$($ep.Name)' (IP $($ep.IPAddress), MAC $($ep.MacAddress)) ..."
                try { Remove-HnsEndpoint $ep } catch { Write-Host "    WARNING: $($_.Exception.Message)" -ForegroundColor Yellow }
            }
        }
    }
    else {
        Write-Host "  HNS helper cmdlets unavailable; skipping endpoint prune." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
#  Clean up per-pod working directories.
# ------------------------------------------------------------
Write-Section "Cleaning working directories"
$dirs = @(if ($All) {
    @(Get-ChildItem -Path $DownloadDir -Directory -Filter 'pod-*' -ErrorAction SilentlyContinue)
}
else {
    @(Get-Item -Path (Join-Path $DownloadDir "pod-$PodName") -ErrorAction SilentlyContinue)
})
if (-not @($dirs).Count) {
    Write-Host "  No pod working directories to remove."
}
else {
    foreach ($d in $dirs) {
        Remove-Item -Path $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  Removed $($d.FullName)"
    }
}

Write-Section "Done"
Write-Host "Remaining pods:" -ForegroundColor Cyan
& $CrictlExe pods 2>&1 | ForEach-Object { Write-Host "  $_" }
