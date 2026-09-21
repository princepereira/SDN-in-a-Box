# ============================================================
#  Delete-L2Vm-Linux.ps1
# ------------------------------------------------------------
#  Tear down an L2 (nested Linux) VM created by
#  Create-L2Vm-Linux.ps1:
#    1. Stop the VM (force / turn off) if it is running.
#    2. Remove it from Hyper-V.
#    3. Delete its per-VM directory under C:\L2VMs
#       (C:\L2VMs\<L2VMName>, holding <name>.vhdx and <name>-seed.iso).
#    4. Free its IP from the used-IPs ledger (C:\L2VMs\used_ips.json)
#       so future auto-allocations can reuse it.
#
#  USAGE
#    .\Delete-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1"
#    .\Delete-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -Force
#    .\Delete-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -KeepFiles
# ============================================================
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    # Name of the L2 VM to delete (matches Create-L2Vm-Linux.ps1 -L2VMName).
    [Parameter(Mandatory = $true)]
    [string]$L2VMName,

    # Root folder that holds per-VM directories + the IP ledger (matches $VmRoot).
    [string]$VmRoot = "C:\L2VMs",

    # Delete the VM only; keep the per-VM directory and the IP-ledger entry.
    [switch]$KeepFiles,

    # Skip the confirmation prompt.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-Section { param([string]$Text) Write-Host "`n==== $Text ====" -ForegroundColor Cyan }

$vmName      = $L2VMName
$vmDir       = Join-Path $VmRoot $vmName
$UsedIpsFile = Join-Path $VmRoot 'used_ips.json'

Write-Section "Deleting L2 VM '$vmName'"

$vm = Get-VM -Name $vmName -ErrorAction SilentlyContinue
if (-not $vm) {
    Write-Host "  VM '$vmName' not found in Hyper-V (already deleted?)." -ForegroundColor Yellow
}

# ---- Confirm (unless -Force) ----
if (-not $Force) {
    $targets = @("VM '$vmName' (Hyper-V)")
    if (-not $KeepFiles) { $targets += "directory '$vmDir'"; $targets += "IP-ledger entry in '$UsedIpsFile'" }
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

    # ---- Dismount any attached disks before removing the VM ----
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

# ---- 3. Delete the per-VM directory ----
if ($KeepFiles) {
    Write-Host "  -KeepFiles set; leaving '$vmDir' and the IP-ledger entry in place." -ForegroundColor Yellow
}
else {
    if (Test-Path $vmDir) {
        Write-Host "  Deleting per-VM directory '$vmDir'..."
        Get-ChildItem -Path $vmDir -Filter *.vhdx -File -ErrorAction SilentlyContinue | ForEach-Object {
            $info = Get-VHD -Path $_.FullName -ErrorAction SilentlyContinue
            if ($info -and $info.Attached) { Dismount-VHD -Path $_.FullName -ErrorAction SilentlyContinue }
        }
        Remove-Item -Path $vmDir -Recurse -Force
        Write-Host "  Directory deleted." -ForegroundColor Green
    }
    else {
        Write-Host "  Directory '$vmDir' not found (nothing to delete)." -ForegroundColor Yellow
    }

    # ---- 4. Free the IP from the used-IPs ledger ----
    if (Test-Path $UsedIpsFile) {
        try {
            $entries = @(Get-Content -Path $UsedIpsFile -Raw | ConvertFrom-Json)
            $remaining = @($entries | Where-Object { $_.Name -ne $vmName })
            if ($remaining.Count -ne $entries.Count) {
                ($remaining | ConvertTo-Json -Depth 4) | Set-Content -Path $UsedIpsFile -Encoding UTF8
                Write-Host "  Freed IP-ledger entry for '$vmName' in '$UsedIpsFile'." -ForegroundColor Green
            }
            else {
                Write-Host "  No IP-ledger entry for '$vmName' found in '$UsedIpsFile'." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Warning "Could not update IP ledger ($UsedIpsFile): $($_.Exception.Message)"
        }
    }
}

Write-Section "Done"
Write-Host "L2 VM '$vmName' teardown complete."
