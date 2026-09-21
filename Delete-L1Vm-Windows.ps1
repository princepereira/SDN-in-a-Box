# ============================================================
#  Delete-L1Vm-Windows.ps1
# ------------------------------------------------------------
#  Tear down an L1 (nested Windows) VM created by
#  Create-L1Vm-Windows.ps1:
#    1. Stop the VM (force / turn off) if it is running.
#    2. Remove it from Hyper-V.
#    3. Delete its per-VM disk directory under C:\VHDs
#       (C:\VHDs\<VMName>, which holds the per-VM differencing disk).
#
#  The read-only BASE image that the differencing disk was created
#  from lives at the original -VHDXPath (a DIFFERENT location) and is
#  deliberately left untouched so it stays reusable for new VMs.
#
#  USAGE
#    .\Delete-L1Vm-Windows.ps1
#    .\Delete-L1Vm-Windows.ps1 -L1VMName "L1-GeCur-2025"
#    .\Delete-L1Vm-Windows.ps1 -L1VMName "L1-GeCur-2025" -Force
#    .\Delete-L1Vm-Windows.ps1 -L1VMName "L1-GeCur-2025" -KeepFiles
# ============================================================
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Name of the L1 VM to delete (matches Create-L1Vm-Windows.ps1 -L1VMName).
    [string]$L1VMName = "L1-GeCurNv-2025",

    # Root folder that holds per-VM disk directories (matches $localVhdRoot).
    [string]$VhdRoot = "C:\VHDs",

    # Delete the VM only; keep the per-VM disk directory on disk.
    [switch]$KeepFiles,

    # Skip the confirmation prompt.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Section { param([string]$Text) Write-Host "`n==== $Text ====" -ForegroundColor Cyan }

$vmName    = $L1VMName
$vmDiskDir = Join-Path $VhdRoot $vmName

Write-Section "Deleting L1 VM '$vmName'"

$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "  VM '$vmName' not found in Hyper-V (already deleted?)." -ForegroundColor Yellow
}

# ---- Confirm (unless -Force) ----
if (-not $Force) {
    $targets = @("VM '$vmName' (Hyper-V)")
    if (-not $KeepFiles) { $targets += "directory '$vmDiskDir'" }
    if (-not $PSCmdlet.ShouldProcess(($targets -join ' + '), 'Delete')) {
        Write-Host "  Aborted (no changes made)." -ForegroundColor Yellow
        return
    }
}

# ---- 1. Stop the VM if it is running ----
if ($vm) {
    if ($vm.State -ne 'Off') {
        Write-Host "  Stopping VM '$vmName' (current state: $($vm.State))..."
        Stop-VM -Name $vmName -TurnOff -Force -ErrorAction SilentlyContinue
        Start-Sleep 2
    }

    # ---- Capture disk paths before removing the VM, then dismount any attached ----
    $diskPaths = @()
    try { $diskPaths = (Get-VMHardDiskDrive -VMName $vmName -ErrorAction SilentlyContinue).Path } catch {}
    foreach ($d in $diskPaths) {
        $info = Get-VHD -Path $d -ErrorAction SilentlyContinue
        if ($info -and $info.Attached) { Dismount-VHD -Path $d -ErrorAction SilentlyContinue }
    }

    # ---- 2. Remove the VM from Hyper-V ----
    Write-Host "  Removing VM '$vmName' from Hyper-V..."
    Remove-VM -Name $vmName -Force
    Write-Host "  VM removed." -ForegroundColor Green
}

# ---- 3. Delete the per-VM disk directory ----
if ($KeepFiles) {
    Write-Host "  -KeepFiles set; leaving '$vmDiskDir' in place." -ForegroundColor Yellow
}
elseif (Test-Path $vmDiskDir) {
    Write-Host "  Deleting per-VM disk directory '$vmDiskDir'..."
    # Dismount any VHD still attached from this directory before deleting.
    Get-ChildItem -Path $vmDiskDir -Filter *.vhdx -File -ErrorAction SilentlyContinue | ForEach-Object {
        $info = Get-VHD -Path $_.FullName -ErrorAction SilentlyContinue
        if ($info -and $info.Attached) { Dismount-VHD -Path $_.FullName -ErrorAction SilentlyContinue }
    }
    Remove-Item -Path $vmDiskDir -Recurse -Force
    Write-Host "  Directory deleted." -ForegroundColor Green
}
else {
    Write-Host "  Directory '$vmDiskDir' not found (nothing to delete)." -ForegroundColor Yellow
}

Write-Section "Done"
Write-Host "L1 VM '$vmName' teardown complete."
