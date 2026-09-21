# ============================================================
#  Create-L2Vm-Linux.ps1
#  Brings up a nested L2 Ubuntu Server VM on Hyper-V INSIDE the L1 VM
#  from the official Ubuntu CLOUD IMAGE (qcow2) -- NOT the ISO installer.
#  There is NO subiquity installer and NO 'yes' keypress: the pre-built
#  cloud image is converted to VHDX and booted directly, and a generated
#  cloud-init (NoCloud) seed configures it on first boot:
#    - login ubuntu / host ubuntu / password ubuntu@123 (sudo, SSH pw login)
#    - OpenSSH Server + preinstalled tools (python3, net-tools/ifconfig,
#      jq, curl, tcpdump, ...)
#    - a PERSISTENT static IP + DNS (netplan) applied on first boot
#
#  Requires qemu-img to convert the cloud image to VHDX. If not on PATH it
#  is auto-downloaded (portable) from $QemuImgUrl.
#
#  Run this in an ELEVATED PowerShell session INSIDE the L1 VM
#  (the L1 VM must already have the Hyper-V role + a guest vSwitch).
#
#  Usage:
#    # Name only: the next free IP in the subnet is auto-allocated + persisted.
#    .\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1"
#    # Pin a specific IP:
#    .\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -IPAddress 192.168.100.10
#    # Auto-allocate from a specific subnet:
#    .\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -SubnetCidr 192.168.50.0/24
#    # Attach to a manually-created internal/NAT switch instead of the default:
#    .\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -SwitchName "InternalNAT"
# ============================================================

[CmdletBinding()]
param(
    # Name of the L2 Ubuntu VM to create.
    [Parameter(Mandatory = $true)]
    [string]$L2VMName,

    # Static IPv4 address for the L2 VM, e.g. 192.168.100.10. OPTIONAL: if omitted,
    # the next free host IP in -SubnetCidr is auto-selected (skipping the network,
    # broadcast, gateway, and any IP already recorded in the used-IPs JSON file).
    [Parameter(Mandatory = $false)]
    [string]$IPAddress,

    # Subnet (CIDR) to auto-allocate the L2 IP from when -IPAddress is not given.
    [Parameter(Mandatory = $false)]
    [string]$SubnetCidr,

    # Optional path to the Ubuntu cloud image (.img, qcow2). Defaults to the
    # image downloaded to C:\ISOs (auto-downloaded here if missing).
    [Parameter(Mandatory = $false)]
    [string]$CloudImagePath,

    # Optional name of the L1 guest virtual switch to attach the L2 VM to.
    # Defaults to 'IntVirtSwitch' (created by Create-L1Vm-Windows.ps1). Set this
    # to your manually-created internal/NAT switch name if different.
    [Parameter(Mandatory = $false)]
    [string]$SwitchName
)

$ErrorActionPreference = 'Stop'

# ---- Static config / constants ----
# Default networking model: an INTERNAL switch + NAT (auto-discovered, or created
# here from the subnet implied by -IPAddress). Pass -SwitchName to override and
# attach to a specific existing switch instead.
$InternalSwitchName = 'IntVirtSwitch'         # internal NAT switch (also created by L1 script)
$NatName            = 'UbuntuNat'            # NetNat name for the internal subnet
$VfpExtensionName   = 'Microsoft Azure VFP Switch Extension'

# ---- Ubuntu cloud image + qemu-img (qcow2 -> VHDX) ----
$CloudImageUrl   = 'https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img'
$ImageCacheDir   = 'C:\ISOs'                                            # where the .img is cached
$DefaultImagePath = Join-Path $ImageCacheDir 'ubuntu-26.04-server-cloudimg-amd64.img'
$QemuImgUrl      = 'https://cloudbase.it/downloads/qemu-img-win-x64-2_3_0.zip'  # portable qemu-img
$QemuImgDir      = 'C:\Tools\qemu-img'                                  # extracted qemu-img location

$StartupRAMMB  = 2048                        # RAM in MB
$VProcCount    = 2                           # virtual processors
$VhdSizeGB     =30                          # OS disk size (cloud image is grown to this)
$VmRoot        = 'C:\L2VMs'                  # where L2 VM disks live

# ---- IP auto-allocation (when -IPAddress is omitted) ----
$DefaultSubnetCidr = '192.168.100.0/24'      # subnet to allocate L2 IPs from
$UsedIpsFile       = Join-Path $VmRoot 'used_ips.json'   # persisted IP ledger

# ---- Guest (Ubuntu) identity + network constants ----
$UbuntuRealName = 'ubuntu'
$UbuntuHostName = 'ubuntu'
$UbuntuUsername = 'ubuntu'
$UbuntuPassword = 'ubuntu@123'                # plaintext (for the summary + MobaXterm session)
# SHA-512 crypt hash of 'ubuntu@123' (cloud-init requires a hashed password).
$UbuntuPwHash   = '$6$KXyOi0xDygk5Bg2c$8tFE7ibhOQ936fpgcacsJvFDhUxMhuUzaMtpdrKhWb1mHL4sllPv9ouCAvQkOBd7de/H4fT09KsSzXE1zuwxq/'
$PrefixLength   = 24
$DnsServer      = '8.8.8.8'

# ---- Packages to preinstall on first boot (cloud-init) ----
$ExtraPackages = @(
    'python3', 'net-tools', 'jq', 'curl', 'tcpdump',
    'iproute2', 'iputils-ping', 'dnsutils', 'openssh-server'
)

# ---- VFP port connectivity (the 'Ethernet' switch runs the Azure VFP
#      extension, so L2 ports come up fail-closed/blocked until unblocked) ----
$EnableVfpConnectivity = $true
$VfpIncludeIPv6        = $true
$VfpCtrlPath           = 'vfpctrl'                 # vfpctrl.exe (System32, on PATH)
$VfpLayerName          = 'CONNECTIVITY_ACL_LAYER'
$VfpLayerPriority      = 100
$VfpPortWaitSeconds    = 90                        # wait for the L2 VFP port to appear

# ---- MobaXterm session (the client itself is installed by Create-L1Vm-Windows.ps1) ----
# This script only ADDS an SSH session/bookmark for the new VM; it does not
# download or install MobaXterm or touch PATH (that is done once by the L1 script).
$AddMobaXtermSession = $true
$LaunchMobaXterm     = $true
$MobaXtermDir        = 'C:\Tools\MobaXterm'       # where the L1 script installed it
$MobaXtermSshPort    = 22
$RestartMobaXtermIfRunning = $true                # close+relaunch so new sessions appear

# ------------------------------------------------------------
#  Helper: create an ISO image from a folder using built-in IMAPI2
#  (no external tools needed). Used to build the cloud-init seed.
# ------------------------------------------------------------
function New-IsoFile {
    param(
        [Parameter(Mandatory)][string]$SourceDir,
        [Parameter(Mandatory)][string]$DestinationIso,
        [string]$VolumeName = 'CIDATA'
    )

    if (-not ([System.Management.Automation.PSTypeName]'ISOFile').Type) {
        $code = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class ISOFile {
    public static void Create(string path, object stream, int blockSize, int totalBlocks) {
        IStream i = stream as IStream;
        FileStream o = System.IO.File.OpenWrite(path);
        byte[] buf = new byte[blockSize];
        IntPtr bytesReadPtr = Marshal.AllocHGlobal(4);
        try {
            while (totalBlocks-- > 0) {
                i.Read(buf, blockSize, bytesReadPtr);
                int read = Marshal.ReadInt32(bytesReadPtr);
                o.Write(buf, 0, read);
            }
            o.Flush();
        } finally {
            o.Close();
            Marshal.FreeHGlobal(bytesReadPtr);
        }
    }
}
'@
        Add-Type -TypeDefinition $code -ErrorAction Stop
    }

    $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $fsi.VolumeName = $VolumeName
    $fsi.FileSystemsToCreate = 3   # ISO9660 + Joliet
    $fsi.Root.AddTree($SourceDir, $false)
    $result = $fsi.CreateResultImage()

    if (Test-Path $DestinationIso) { Remove-Item $DestinationIso -Force }
    [ISOFile]::Create($DestinationIso, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)
    Write-Host "Created seed ISO: $DestinationIso (label=$VolumeName)"
}

# ------------------------------------------------------------
#  Helper: build the cloud-init NoCloud seed ISO for a CLOUD IMAGE
#  (standard cloud-config -- NOT autoinstall). Configures the ubuntu
#  user + password, preinstalls packages, and applies a persistent
#  static IP via a NoCloud 'network-config' (netplan v2) file.
# ------------------------------------------------------------
function New-CloudInitSeedIso {
    param(
        [Parameter(Mandatory)][string]$SeedIsoPath,
        [Parameter(Mandatory)][string]$IPAddress,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][int]$Prefix,
        [Parameter(Mandatory)][string]$Dns
    )

    $seedDir = Join-Path $env:TEMP ("cidata_" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $seedDir -Force | Out-Null

    # meta-data (NoCloud requires this file, even if minimal).
    $metaData = @"
instance-id: $UbuntuHostName-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))
local-hostname: $UbuntuHostName
"@

    # network-config: NoCloud netplan v2. 'match: name: e*' matches whatever the
    # Hyper-V NIC is named (eth0/enpXsY). Written to the guest's /etc/netplan so
    # the static IP/DNS PERSISTS across reboots.
    $networkConfig = @"
version: 2
ethernets:
  hv0:
    match:
      name: "e*"
    set-name: eth0
    dhcp4: false
    dhcp6: false
    addresses:
      - $IPAddress/$Prefix
    routes:
      - to: default
        via: $Gateway
    nameservers:
      addresses:
        - $Dns
"@

    # user-data: standard cloud-config. Sets the ubuntu user's password + sudo,
    # enables SSH password login, and preinstalls the requested tooling.
    $pkgLines = ($ExtraPackages | ForEach-Object { "  - $_" }) -join "`n"
    $userData = @"
#cloud-config
hostname: $UbuntuHostName
fqdn: $UbuntuHostName
manage_etc_hosts: true
ssh_pwauth: true
disable_root: false

users:
  - name: $UbuntuUsername
    gecos: $UbuntuRealName
    groups: [adm, sudo]
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    shell: /bin/bash
    lock_passwd: false
    passwd: "$UbuntuPwHash"

chpasswd:
  expire: false

package_update: true
package_upgrade: false
packages:
$pkgLines

runcmd:
  - [ systemctl, enable, --now, ssh ]

final_message: "cloud-init finished: L2 Ubuntu ready on $IPAddress"
"@

    # NoCloud files must be UTF-8 (no BOM) and named exactly user-data /
    # meta-data / network-config.
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText((Join-Path $seedDir 'meta-data'),       ($metaData      -replace "`r`n", "`n"), $enc)
    [System.IO.File]::WriteAllText((Join-Path $seedDir 'user-data'),       ($userData      -replace "`r`n", "`n"), $enc)
    [System.IO.File]::WriteAllText((Join-Path $seedDir 'network-config'),  ($networkConfig -replace "`r`n", "`n"), $enc)

    New-IsoFile -SourceDir $seedDir -DestinationIso $SeedIsoPath -VolumeName 'CIDATA'
    Remove-Item $seedDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ------------------------------------------------------------
#  Helper: resolve qemu-img.exe (used to convert the qcow2 cloud image
#  to VHDX). Uses one on PATH if present, else downloads a portable build.
# ------------------------------------------------------------
function Get-QemuImg {
    $onPath = Get-Command 'qemu-img.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    $local = Join-Path $QemuImgDir 'qemu-img.exe'
    if (Test-Path $local) { return $local }

    Write-Host "qemu-img not found; downloading portable build from $QemuImgUrl ..."
    if (-not (Test-Path $QemuImgDir)) { New-Item -ItemType Directory -Path $QemuImgDir -Force | Out-Null }
    $zip = Join-Path $env:TEMP 'qemu-img.zip'
    try {
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $QemuImgUrl -OutFile $zip -UseBasicParsing
        $ProgressPreference = $prev
        Expand-Archive -Path $zip -DestinationPath $QemuImgDir -Force
    }
    catch { throw "Failed to obtain qemu-img from $QemuImgUrl : $($_.Exception.Message)" }
    finally { Remove-Item $zip -Force -ErrorAction SilentlyContinue }

    # The zip may extract into a subfolder; find qemu-img.exe underneath.
    $exe = Get-ChildItem -Path $QemuImgDir -Filter 'qemu-img.exe' -Recurse -ErrorAction SilentlyContinue |
           Select-Object -First 1
    if (-not $exe) { throw "qemu-img.exe not found after extracting $QemuImgUrl to $QemuImgDir." }
    return $exe.FullName
}

# ------------------------------------------------------------
#  Helper: convert the Ubuntu cloud image (qcow2 .img) to a dynamic
#  VHDX Hyper-V can boot, then grow it to the requested size.
# ------------------------------------------------------------
function Convert-CloudImageToVhdx {
    param(
        [Parameter(Mandatory)][string]$SourceImg,
        [Parameter(Mandatory)][string]$DestVhdx,
        [Parameter(Mandatory)][int]$SizeGB
    )
    $qemu = Get-QemuImg
    if (Test-Path $DestVhdx) { Remove-Item $DestVhdx -Force }

    Write-Host "Converting cloud image to VHDX (qemu-img)..."
    Write-Host "  $qemu convert -p -f qcow2 -O vhdx -o subformat=dynamic `"$SourceImg`" `"$DestVhdx`"" -ForegroundColor Cyan
    & $qemu convert -p -f qcow2 -O vhdx -o subformat=dynamic $SourceImg $DestVhdx
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $DestVhdx)) {
        throw "qemu-img conversion failed (exit $LASTEXITCODE). Source: $SourceImg"
    }

    # Grow the virtual disk; cloud-init growpart/resizefs expands the root FS on boot.
    try {
        Resize-VHD -Path $DestVhdx -SizeBytes ($SizeGB * 1GB) -ErrorAction Stop
        Write-Host "  Resized VHDX to $SizeGB GB (cloud-init will grow the root partition)."
    }
    catch { Write-Warning "  Could not resize VHDX to $SizeGB GB: $($_.Exception.Message)" }
}

# ------------------------------------------------------------
#  Helper: LOCATE MobaXterm.exe (installed by the L1 script). Does NOT download
#  or install -- that is handled once by Create-L1Vm-Windows.ps1.
# ------------------------------------------------------------
function Find-MobaXterm {
    # Portable copy provisioned by the L1 script?
    $portable = Get-ChildItem -Path $MobaXtermDir -Filter 'MobaXterm*.exe' -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -notmatch 'Uninstall' } | Select-Object -First 1
    if ($portable) { return $portable.FullName }

    # Installed edition / on PATH?
    foreach ($p in @(
        "$env:ProgramFiles\Mobatek\MobaXterm\MobaXterm.exe",
        "${env:ProgramFiles(x86)}\Mobatek\MobaXterm\MobaXterm.exe")) {
        if (Test-Path $p) { return $p }
    }
    $onPath = Get-Command 'MobaXterm.exe' -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    return $null
}

# ------------------------------------------------------------
#  Helper: add (or refresh) an SSH session bookmark in MobaXterm.ini so the
#  new L2 VM appears in MobaXterm's session list. Session type 109 = SSH.
# ------------------------------------------------------------
function Add-MobaXtermSession {
    param(
        [Parameter(Mandatory)][string]$ExePath,
        [Parameter(Mandatory)][string]$SessionName,
        [Parameter(Mandatory)][string]$SshHost,
        [int]$Port = 22,
        [string]$User = 'ubuntu',
        [string]$Password = ''
    )
    # Portable MobaXterm reads MobaXterm.ini next to the exe. Sessions live under
    # a [Bookmarks] section, one line each: <name>=#109#0%host%port%user%password%...
    # NOTE: MobaXterm normally keeps passwords in its own encrypted store, so it may
    # still prompt once and offer to save; the password is placed in the session's
    # password field as a best effort.
    $iniPath = Join-Path (Split-Path -Parent $ExePath) 'MobaXterm.ini'
    $line = ('{0}=#109#0%{1}%{2}%{3}%{4}%-1%-1%%%22%%0%0%0%%%-1%0%0%0%%1080%%0%0%1#MobaFont%10%0%0%-1%15%236,236,236%30,30,30%180,180,192%0%-1%0%%xterm%-1%-1%_Std_Colors_0_%80%24%0%1%-1%<none>%%0%0%-1#0# -1' -f `
             $SessionName, $SshHost, $Port, $User, $Password)

    if (Test-Path $iniPath) { $existing = Get-Content -Path $iniPath -ErrorAction SilentlyContinue }
    else                    { $existing = @('[Bookmarks]', 'SubRep=', 'ImgNum=41') }

    $lines = [System.Collections.Generic.List[string]]::new()
    if ($existing) { $lines.AddRange([string[]]$existing) }

    # Ensure a [Bookmarks] section exists.
    $bmIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -ieq '[Bookmarks]') { $bmIndex = $i; break } }
    if ($bmIndex -lt 0) {
        if ($lines.Count -gt 0) { $lines.Add('') }
        $bmIndex = $lines.Count
        $lines.Add('[Bookmarks]'); $lines.Add('SubRep='); $lines.Add('ImgNum=41')
    }

    # Remove any existing session with the same name (idempotent refresh).
    for ($i = $lines.Count - 1; $i -gt $bmIndex; $i--) {
        if ($lines[$i] -match ('^{0}=#' -f [regex]::Escape($SessionName))) { $lines.RemoveAt($i) }
    }

    # Insert after the section's SubRep=/ImgNum= header lines.
    $insertAt = $bmIndex + 1
    for ($i = $bmIndex + 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\s*\[') { break }
        if ($lines[$i] -match '^(SubRep|ImgNum)=') { $insertAt = $i + 1 }
    }
    $lines.Insert($insertAt, $line)

    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllLines($iniPath, $lines, $enc)
    Write-Host "  Added MobaXterm session '$SessionName' -> $User@${SshHost}:$Port" -ForegroundColor Green
}

# ------------------------------------------------------------
#  Helper: ensure the VFP forwarding extension service (vfpext) is running.
#  If it is stopped, VFP port policy cannot be programmed (vfpctrl returns
#  "Error (2)"), so force-restart it.
# ------------------------------------------------------------
function Assert-VfpExtRunning {
    $svc = Get-Service -Name 'vfpext' -ErrorAction SilentlyContinue
    if (-not $svc) {
        Write-Warning "vfpext service not found; the VFP extension may not be installed on this host."
        return
    }
    if ($svc.Status -eq 'Running') {
        Write-Host "vfpext service is Running." -ForegroundColor Green
        return
    }
    Write-Host "vfpext service is '$($svc.Status)'; restarting..." -ForegroundColor Yellow
    try {
        Restart-Service -Name 'vfpext' -Force -ErrorAction Stop
        Write-Host "  vfpext restarted." -ForegroundColor Green
    }
    catch {
        try {
            Start-Service -Name 'vfpext' -ErrorAction Stop
            Write-Host "  vfpext started." -ForegroundColor Green
        }
        catch { Write-Warning "  Could not start vfpext: $($_.Exception.Message)" }
    }
}

# ------------------------------------------------------------
#  Helper: unblock the L2 VM's VFP port and install a permissive
#  ACL policy (VM<->VM, VM->host gateway->internet, DHCP v4/v6).
#  Integrated from Enable-VfpPortConnectivity.ps1 (always applies).
# ------------------------------------------------------------
function Enable-VfpPortConnectivity {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [string]$VfpCtrl       = 'vfpctrl',
        [string]$LayerName     = 'CONNECTIVITY_ACL_LAYER',
        [int]   $LayerPriority = 100,
        [bool]  $IncludeIPv6   = $true,
        [int]   $PortWaitSeconds = 90
    )

    $G_V4_OUT = 'CONN_ACL_IPV4_OUT'; $G_V4_IN = 'CONN_ACL_IPV4_IN'
    $G_V6_OUT = 'CONN_ACL_IPV6_OUT'; $G_V6_IN = 'CONN_ACL_IPV6_IN'
    $PRI_DHCP = 100; $PRI_ALLOW = 60000

    # Run a vfpctrl command and report success/failure. When a VFP switch GUID
    # has been resolved, scope every call with /switch so the port is found even
    # when multiple VFP-enabled switches exist (Ethernet + IntVirtSwitch).
    function Invoke-Vfp {
        param([string[]]$VfpArgs, [string]$Comment)
        if ($SwitchId) { $VfpArgs = @('/switch', $SwitchId) + $VfpArgs }
        $display = '{0} {1}' -f $VfpCtrl, ($VfpArgs -join ' ')
        if ($Comment) { Write-Host "  # $Comment" -ForegroundColor DarkGray }
        Write-Host "  $display" -ForegroundColor Cyan
        $out = & $VfpCtrl @VfpArgs 2>&1
        $ok  = ($LASTEXITCODE -eq 0) -and ($out -notmatch 'failed')
        $color = if ($ok) { 'Green' } else { 'Red' }
        ($out | Out-String).TrimEnd().Split("`n") | ForEach-Object {
            if ($_ -ne '') { Write-Host "      $_" -ForegroundColor $color }
        }
        if (-not $ok) { Write-Warning "Command reported failure: $display" }
    }

    # Resolve a VFP port GUID (and its owning switch GUID) from a VM name.
    function Resolve-VfpPortByVmName {
        param([string]$Name)
        $raw = & $VfpCtrl '/list-vmswitch-port' 2>&1
        if ($LASTEXITCODE -ne 0) { throw "vfpctrl /list-vmswitch-port failed: $($raw | Out-String)" }
        $lines = ($raw | Out-String) -split "`r?`n"
        $currentPort = $null; $currentSwitch = $null; $found = @()
        foreach ($line in $lines) {
            if ($line -match '^\s*Port name\s*:\s*(.+?)\s*$') { $currentPort = $Matches[1].Trim(); $currentSwitch = $null }
            elseif ($line -match '^\s*Switch name\s*:\s*(.+?)\s*$') { $currentSwitch = $Matches[1].Trim() }
            elseif ($line -match '^\s*VM name\s*:\s*(.+?)\s*$') {
                $vm = $Matches[1].Trim()
                if ($currentPort -and $vm -and ($vm -ieq $Name)) {
                    $found += [pscustomobject]@{ Port = $currentPort; Switch = $currentSwitch; Vm = $vm }
                }
            }
        }
        if ($found.Count -eq 0) { return $null }
        if (($found | Select-Object -ExpandProperty Port -Unique).Count -gt 1) {
            throw "VM name '$Name' maps to multiple VFP ports. Resolve manually."
        }
        return $found[0]
    }

    # add-rule-ex: [id name proto src_ip src_prt dest_ip dest_prt flag ttl pri type]
    function Add-AllowRule {
        param(
            [string]$Group, [string]$Id, [string]$Proto = '*',
            [string]$SrcPrt = '*', [string]$DestPrt = '*',
            [int]$Flag = 1, [int]$Ttl = 0, [int]$Pri = 60000, [string]$Comment = ''
        )
        $rule = @($Id, $Id, $Proto, '*', $SrcPrt, '*', $DestPrt, $Flag, $Ttl, $Pri, 'allow')
        Invoke-Vfp -Comment $Comment -VfpArgs @(
            '/port', $Port, '/layer', $LayerName, '/group', $Group,
            '/add-rule-ex', ('"{0}"' -f ($rule -join ' ')))
    }

    # Ensure vfpctrl is available.
    if (-not (Get-Command $VfpCtrl -ErrorAction SilentlyContinue)) {
        Write-Warning "vfpctrl not found ('$VfpCtrl'); skipping VFP connectivity. The L2 VM may be network-blocked."
        return
    }

    # The VFP port only exists after the VM starts and its vNIC attaches; wait.
    Write-Host "`nWaiting for the L2 VFP port to appear (up to $PortWaitSeconds s)..." -ForegroundColor White
    $Port = $null; $SwitchId = $null
    $deadline = (Get-Date).AddSeconds($PortWaitSeconds)
    while (-not $Port -and (Get-Date) -lt $deadline) {
        try {
            $pi = Resolve-VfpPortByVmName -Name $VMName
            if ($pi) { $Port = $pi.Port; $SwitchId = $pi.Switch }
        } catch { }
        if (-not $Port) { Start-Sleep -Seconds 3 }
    }
    if (-not $Port) {
        Write-Warning "Could not resolve a VFP port for '$VMName'. Skipping; once the VM is up run: Enable-VfpPortConnectivity.ps1 -VMName '$VMName' -Execute"
        return
    }
    Write-Host "  -> VFP port $Port (switch $SwitchId)" -ForegroundColor Green

    Write-Host "`n=== Enabling connectivity on VFP port $Port ===" -ForegroundColor White

    # 0) Enable VFP policy on the port. Without this the port has VFP loaded but
    #    no policy object, so /unblock-port and /add-layer fail with "Error (2)".
    #    (On SDN hosts the NC/SLB agent does this; on a standalone lab we must.)
    Write-Host "Enable VFP on port:" -ForegroundColor White
    Invoke-Vfp -Comment "enable VFP policy on port" -VfpArgs @('/port', $Port, '/enable-port')

    # 1) Clear blocks (durable across restore).
    Write-Host "Clear port block:" -ForegroundColor White
    Invoke-Vfp -Comment "unblock now"        -VfpArgs @('/port', $Port, '/unblock-port')
    Invoke-Vfp -Comment "unblock on restore" -VfpArgs @('/port', $Port, '/unblock-port-on-restore')

    # 2) Stateless default-allow ACL layer.
    Write-Host "`nACL layer:" -ForegroundColor White
    Invoke-Vfp -Comment "default-allow ACL layer" -VfpArgs @(
        '/port', $Port, '/add-layer',
        ('"{0} {0} stateless {1} 1"' -f $LayerName, $LayerPriority))

    # 3) Groups (IPv4 + optional IPv6).
    Write-Host "`nGroups:" -ForegroundColor White
    Invoke-Vfp -Comment "IPv4 OUT" -VfpArgs @('/port', $Port, '/layer', $LayerName, '/add-group',
        ('"{0} {0} out {1} * * * * * priority_based_auto_condition_opt"' -f $G_V4_OUT, $LayerPriority))
    Invoke-Vfp -Comment "IPv4 IN" -VfpArgs @('/port', $Port, '/layer', $LayerName, '/add-group',
        ('"{0} {0} in {1} * * * * * priority_based_auto_condition_opt"' -f $G_V4_IN, $LayerPriority))
    if ($IncludeIPv6) {
        Invoke-Vfp -Comment "IPv6 OUT" -VfpArgs @('/port', $Port, '/layer', $LayerName, '/add-group',
            ('"{0} {0} outv6 {1} * * * * * priority_based_auto_condition_opt"' -f $G_V6_OUT, $LayerPriority))
        Invoke-Vfp -Comment "IPv6 IN" -VfpArgs @('/port', $Port, '/layer', $LayerName, '/add-group',
            ('"{0} {0} inv6 {1} * * * * * priority_based_auto_condition_opt"' -f $G_V6_IN, $LayerPriority))
    }

    # 4) Rules: explicit DHCP allow + low-priority allow-all.
    Write-Host "`nIPv4 rules:" -ForegroundColor White
    Add-AllowRule -Group $G_V4_OUT -Id 'dhcp_v4_out' -Proto 17 -SrcPrt 68 -DestPrt 67 -Pri $PRI_DHCP -Comment "DHCPv4 request out (udp 68->67)"
    Add-AllowRule -Group $G_V4_IN  -Id 'dhcp_v4_in'  -Proto 17 -SrcPrt 67 -DestPrt 68 -Pri $PRI_DHCP -Comment "DHCPv4 reply in (udp 67->68)"
    Add-AllowRule -Group $G_V4_OUT -Id 'allow_all_v4_out' -Pri $PRI_ALLOW -Comment "allow all IPv4 out"
    Add-AllowRule -Group $G_V4_IN  -Id 'allow_all_v4_in'  -Pri $PRI_ALLOW -Comment "allow all IPv4 in"
    if ($IncludeIPv6) {
        Write-Host "`nIPv6 rules:" -ForegroundColor White
        Add-AllowRule -Group $G_V6_OUT -Id 'dhcp_v6_out' -Proto 17 -SrcPrt 546 -DestPrt 547 -Pri $PRI_DHCP -Comment "DHCPv6 request out (udp 546->547)"
        Add-AllowRule -Group $G_V6_IN  -Id 'dhcp_v6_in'  -Proto 17 -SrcPrt 547 -DestPrt 546 -Pri $PRI_DHCP -Comment "DHCPv6 reply in (udp 547->546)"
        Add-AllowRule -Group $G_V6_OUT -Id 'allow_all_v6_out' -Pri $PRI_ALLOW -Comment "allow all IPv6 out"
        Add-AllowRule -Group $G_V6_IN  -Id 'allow_all_v6_in'  -Pri $PRI_ALLOW -Comment "allow all IPv6 in"
    }

    Write-Host "`nVFP connectivity applied. Verify with:" -ForegroundColor White
    $sw = if ($SwitchId) { "/switch $SwitchId " } else { '' }
    Write-Host "  $VfpCtrl ${sw}/get-port-state /port $Port" -ForegroundColor Gray
    Write-Host "  $VfpCtrl ${sw}/port $Port /list-rule"      -ForegroundColor Gray
}

# ------------------------------------------------------------
#  Helper: ensure gateway IP + NAT plumbing exist for an internal switch.
# ------------------------------------------------------------
function Initialize-NatPlumbing {
    param(
        [Parameter(Mandatory)][string]$SwitchName,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][int]$Prefix,
        [Parameter(Mandatory)][string]$SubnetPrefix,
        [Parameter(Mandatory)][string]$NatName
    )
    $alias = "vEthernet ($SwitchName)"

    # Wait for the host vNIC created by the internal switch to appear.
    $deadline = (Get-Date).AddSeconds(30)
    while (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
    }

    # Assign the gateway IP to the host vNIC if not already present.
    $hasIp = Get-NetIPAddress -InterfaceAlias $alias -IPAddress $Gateway -ErrorAction SilentlyContinue
    if (-not $hasIp) {
        try {
            New-NetIPAddress -InterfaceAlias $alias -IPAddress $Gateway -PrefixLength $Prefix -ErrorAction Stop | Out-Null
            Write-Host "  Assigned gateway $Gateway/$Prefix to '$alias'."
        }
        catch { Write-Warning "  Could not assign $Gateway/$Prefix to '$alias': $($_.Exception.Message)" }
    }

    # Enable the Azure VFP forwarding extension on the internal switch so L2 ports
    # are governed by VFP (matching the manual 'Enable-VMSwitchExtension' step).
    # Enabling right after switch creation can silently not stick, so verify + retry.
    try {
        $ext = Get-VMSwitchExtension -VMSwitchName $SwitchName -Name $VfpExtensionName -ErrorAction SilentlyContinue
        if ($ext) {
            $enabled = [bool]$ext.Enabled
            for ($i = 1; $i -le 5 -and -not $enabled; $i++) {
                try { Enable-VMSwitchExtension -VMSwitchName $SwitchName -Name $VfpExtensionName -ErrorAction Stop | Out-Null } catch {}
                Start-Sleep -Seconds 3
                $enabled = [bool](Get-VMSwitchExtension -VMSwitchName $SwitchName -Name $VfpExtensionName -ErrorAction SilentlyContinue).Enabled
            }
            if ($enabled) { Write-Host "  VFP extension enabled on '$SwitchName' (verified)." }
            else { Write-Warning "  VFP extension on '$SwitchName' still NOT enabled after retries; run: Enable-VMSwitchExtension -VMSwitchName $SwitchName -Name '$VfpExtensionName'" }
        }
        else { Write-Host "  VFP extension '$VfpExtensionName' not available on this build; skipping enable." }
    }
    catch { Write-Warning "  Could not enable VFP extension on '$SwitchName': $($_.Exception.Message)" }

    # Create a NAT for this subnet if none serves it already.
    $natForSubnet = Get-NetNat -ErrorAction SilentlyContinue |
                    Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $SubnetPrefix }
    if (-not $natForSubnet) {
        $useName = $NatName
        if (Get-NetNat -Name $useName -ErrorAction SilentlyContinue) {
            $useName = "$NatName-$($SubnetPrefix -replace '[./]','-')"   # name taken by another subnet
        }
        try {
            New-NetNat -Name $useName -InternalIPInterfaceAddressPrefix $SubnetPrefix -ErrorAction Stop | Out-Null
            Write-Host "  Created NAT '$useName' for $SubnetPrefix."
        }
        catch { Write-Warning "  Could not create NAT for $SubnetPrefix : $($_.Exception.Message)" }
    }
    else { Write-Host "  NAT already present for $SubnetPrefix ('$($natForSubnet.Name)')." }
}

# ------------------------------------------------------------
#  Helper: resolve the internal NAT switch to use, creating it (with the
#  subnet implied by the L2 IP) if none exists yet.
# ------------------------------------------------------------
function Resolve-InternalNatSwitch {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][int]$Prefix,
        [Parameter(Mandatory)][string]$SubnetPrefix,
        [Parameter(Mandatory)][string]$NatName
    )

    # 1. Preferred internal switch already present (created by the L1 script or a prior run)?
    if (Get-VMSwitch -Name $Name -ErrorAction SilentlyContinue) {
        Write-Host "Using existing internal switch '$Name'."
        Initialize-NatPlumbing -SwitchName $Name -Gateway $Gateway -Prefix $Prefix -SubnetPrefix $SubnetPrefix -NatName $NatName
        return $Name
    }

    # 2. Any existing Internal switch already serving this subnet via NetNat?
    $existingNat = Get-NetNat -ErrorAction SilentlyContinue |
                   Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $SubnetPrefix }
    if ($existingNat) {
        $gwIp = Get-NetIPAddress -IPAddress $Gateway -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($gwIp -and $gwIp.InterfaceAlias -match '^vEthernet \((.+)\)$') {
            Write-Host "Using existing internal NAT switch '$($Matches[1])' (subnet $SubnetPrefix)."
            return $Matches[1]
        }
    }

    # 3. None found: create the internal switch + gateway IP + NAT.
    Write-Host "No internal switch found; creating '$Name' for subnet $SubnetPrefix (gateway $Gateway)..."
    New-VMSwitch -Name $Name -SwitchType Internal | Out-Null
    Initialize-NatPlumbing -SwitchName $Name -Gateway $Gateway -Prefix $Prefix -SubnetPrefix $SubnetPrefix -NatName $NatName
    return $Name
}

# ------------------------------------------------------------
#  Helpers: IPv4 <-> UInt32 and a JSON-backed used-IP ledger so each L2 VM
#  gets the next free host IP in the subnet (skipping network/broadcast/gateway).
# ------------------------------------------------------------
function ConvertTo-UInt32Ip {
    param([Parameter(Mandatory)][string]$Ip)
    $b = ([System.Net.IPAddress]::Parse($Ip)).GetAddressBytes()
    [Array]::Reverse($b)
    return [System.BitConverter]::ToUInt32($b, 0)
}
function ConvertFrom-UInt32Ip {
    param([Parameter(Mandatory)][uint32]$Val)
    $b = [System.BitConverter]::GetBytes($Val)
    [Array]::Reverse($b)
    return ([System.Net.IPAddress]::new($b)).ToString()
}
function Get-UsedIps {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-Path $Path) {
        try { return @(Get-Content -Path $Path -Raw | ConvertFrom-Json) } catch { return @() }
    }
    return @()
}
function Add-UsedIp {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Ip
    )
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $list = [System.Collections.Generic.List[object]]::new()
    foreach ($e in (Get-UsedIps -Path $Path)) {
        # Drop any stale entry for the same IP or the same VM name (idempotent refresh).
        if (($e.Ip -ne $Ip) -and ($e.Name -ne $Name)) { $list.Add($e) }
    }
    $list.Add([pscustomobject]@{ Name = $Name; Ip = $Ip; CreatedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    ($list | ConvertTo-Json -Depth 4) | Set-Content -Path $Path -Encoding UTF8
}
function Get-NextFreeIp {
    param(
        [Parameter(Mandatory)][string]$SubnetCidr,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][string]$UsedIpsFile
    )
    $parts = $SubnetCidr.Split('/')
    if ($parts.Count -ne 2) { throw "Invalid -SubnetCidr '$SubnetCidr' (expected e.g. 192.168.100.0/24)." }
    $prefix   = [int]$parts[1]
    $ipL      = [int64](ConvertTo-UInt32Ip $parts[0])
    $hostBits = 32 - $prefix
    $block    = [int64][math]::Pow(2, $hostBits)
    $network  = $ipL - ($ipL % $block)
    $broadcast = $network + $block - 1

    # Reserved: network, broadcast, gateway, and everything already recorded.
    $used = @{}
    $used[$Gateway] = $true
    foreach ($e in (Get-UsedIps -Path $UsedIpsFile)) { if ($e.Ip) { $used[[string]$e.Ip] = $true } }

    for ($u = $network + 1; $u -lt $broadcast; $u++) {
        $cand = ConvertFrom-UInt32Ip ([uint32]$u)
        if (-not $used.ContainsKey($cand)) { return @{ Ip = $cand; Prefix = $prefix } }
    }
    throw "No free host IP available in $SubnetCidr (all in use per $UsedIpsFile)."
}

# ============================================================
#  Main
# ============================================================
# ---- Determine the L2 hostname from the VM name (e.g. ubuntu@l1-ubu-1) ----
# Linux hostnames are lowercase and may contain only a-z 0-9 and hyphens.
$UbuntuHostName = ($L2VMName.ToLower() -replace '[^a-z0-9-]', '-').Trim('-')
if ([string]::IsNullOrWhiteSpace($UbuntuHostName)) { $UbuntuHostName = 'ubuntu' }

# ---- Determine the L2 IP: explicit -IPAddress, or auto-allocate from the subnet ----
if (-not $SubnetCidr) { $SubnetCidr = $DefaultSubnetCidr }

if ($PSBoundParameters.ContainsKey('IPAddress') -and -not [string]::IsNullOrWhiteSpace($IPAddress)) {
    if ($IPAddress -notmatch '^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$') {
        throw "Invalid -IPAddress: $IPAddress (expected IPv4, e.g. 192.168.100.10)"
    }
    $octets  = $IPAddress.Split('.')
    $gateway = "{0}.{1}.{2}.1" -f $octets[0], $octets[1], $octets[2]
    Write-Host "L2 VM '$L2VMName' -> IP $IPAddress/$PrefixLength (explicit), gateway $gateway, DNS $DnsServer"
}
else {
    # Auto-allocate: gateway is the first host address of the subnet (network + 1),
    # then pick the next free host IP not already recorded in the used-IPs ledger.
    $netParts = $SubnetCidr.Split('/')
    $gateway  = ConvertFrom-UInt32Ip ([uint32]((ConvertTo-UInt32Ip $netParts[0]) + 1))
    $alloc    = Get-NextFreeIp -SubnetCidr $SubnetCidr -Gateway $gateway -UsedIpsFile $UsedIpsFile
    $IPAddress    = $alloc.Ip
    $PrefixLength = $alloc.Prefix
    $octets   = $IPAddress.Split('.')
    Write-Host "L2 VM '$L2VMName' -> auto-selected IP $IPAddress/$PrefixLength from $SubnetCidr, gateway $gateway, DNS $DnsServer" -ForegroundColor Cyan
}

# ---- Resolve the Ubuntu cloud image (REUSE an existing copy; download only if none) ----
if (-not $CloudImagePath) { $CloudImagePath = '' }
if (-not $CloudImagePath -or -not (Test-Path $CloudImagePath)) {
    $candidates = @()
    if ($CloudImagePath) { $candidates += $CloudImagePath }
    $candidates += $DefaultImagePath
    # Any cloud image already staged by the L1 script (C:\ISOs) or a prior run?
    foreach ($dir in @($ImageCacheDir, (Join-Path $env:USERPROFILE 'Downloads'))) {
        if (Test-Path $dir) {
            $candidates += (Get-ChildItem -Path $dir -Filter 'ubuntu-*-server-cloudimg-amd64.img' -File -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending | Select-Object -ExpandProperty FullName)
        }
    }
    $found = $candidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $CloudImagePath = if ($found) { $found } else { $DefaultImagePath }
}
if (-not (Test-Path $CloudImagePath)) {
    Write-Host "Ubuntu cloud image not found locally; downloading from $CloudImageUrl ..."
    $CloudImagePath = $DefaultImagePath
    $imgDir = Split-Path -Parent $CloudImagePath
    if ($imgDir -and -not (Test-Path $imgDir)) { New-Item -ItemType Directory -Path $imgDir -Force | Out-Null }
    try {
        $prev = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $CloudImageUrl -OutFile $CloudImagePath -UseBasicParsing
        $ProgressPreference = $prev
    }
    catch { throw "Failed to download Ubuntu cloud image from $CloudImageUrl : $($_.Exception.Message)" }
    Write-Host "Downloaded cloud image: $CloudImagePath"
}
Write-Host "Using Ubuntu cloud image: $CloudImagePath (reused, no re-download)"

# ---- Guard: VM must not already exist ----
if (Get-VM -Name $L2VMName -ErrorAction SilentlyContinue) {
    throw "A VM named '$L2VMName' already exists. Remove it first, or choose another -L2VMName."
}

# ---- Resolve the virtual switch to attach to ----
$subnetPrefix = "{0}.{1}.{2}.0/{3}" -f $octets[0], $octets[1], $octets[2], $PrefixLength
if ($PSBoundParameters.ContainsKey('SwitchName') -and -not [string]::IsNullOrWhiteSpace($SwitchName)) {
    # Explicit switch requested: it must already exist.
    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        $available = (Get-VMSwitch -ErrorAction SilentlyContinue |
                      ForEach-Object { "$($_.Name) [$($_.SwitchType)]" }) -join ', '
        if (-not $available) { $available = '(none found)' }
        throw ("Virtual switch '$SwitchName' not found in L1. Available switches: $available.")
    }
    Write-Host "Using requested switch '$SwitchName'."
}
else {
    # Auto-discover the internal NAT switch (created by the L1 script or a prior
    # run); if none exists, create it from the subnet implied by -IPAddress.
    $SwitchName = Resolve-InternalNatSwitch -Name $InternalSwitchName -Gateway $gateway `
                    -Prefix $PrefixLength -SubnetPrefix $subnetPrefix -NatName $NatName
}

# ---- Create the OS disk from the cloud image (qcow2 -> VHDX) ----
$vmDir   = Join-Path $VmRoot $L2VMName
if (-not (Test-Path $vmDir)) { New-Item -ItemType Directory -Path $vmDir -Force | Out-Null }
$vhdPath = Join-Path $vmDir "$L2VMName.vhdx"
Convert-CloudImageToVhdx -SourceImg $CloudImagePath -DestVhdx $vhdPath -SizeGB $VhdSizeGB

# ---- Create the Gen-2 VM ----
Write-Host "Creating Gen-2 VM '$L2VMName' (RAM ${StartupRAMMB}MB, switch '$SwitchName')..."
New-VM -Name $L2VMName `
       -MemoryStartupBytes ($StartupRAMMB * 1MB) `
       -Generation 2 `
       -VHDPath $vhdPath `
       -SwitchName $SwitchName | Out-Null

# Static memory + processors.
Set-VMMemory    -VMName $L2VMName -DynamicMemoryEnabled $false -StartupBytes ($StartupRAMMB * 1MB)
Set-VMProcessor -VMName $L2VMName -Count $VProcCount

# ---- Build the cloud-init NoCloud seed ISO ----
$seedIso = Join-Path $vmDir "$L2VMName-seed.iso"
Write-Host "Building cloud-init seed (user + packages + static IP)..."
New-CloudInitSeedIso -SeedIsoPath $seedIso -IPAddress $IPAddress -Gateway $gateway -Prefix $PrefixLength -Dns $DnsServer

# ---- Attach the seed ISO as a DVD drive (NoCloud datasource) ----
Add-VMDvdDrive -VMName $L2VMName -Path $seedIso
$hdd = Get-VMHardDiskDrive -VMName $L2VMName

# ---- Secure Boot OFF + boot the cloud-image HARD DISK ----
# The cloud image already contains GRUB/EFI, so we boot the VHDX directly
# (no installer). cloud-init reads the CIDATA seed on first boot.
Set-VMFirmware -VMName $L2VMName -EnableSecureBoot Off -FirstBootDevice $hdd

# ---- Allow Enhanced Session Mode (host policy) ----
Set-VMHost -EnableEnhancedSessionMode $true

# ---- Start and connect ----
Write-Host "Starting VM '$L2VMName'..."
Start-VM -Name $L2VMName

# ---- Record the IP in the used-IPs ledger so future auto-allocations skip it ----
try { Add-UsedIp -Path $UsedIpsFile -Name $L2VMName -Ip $IPAddress; Write-Host "Recorded $IPAddress for '$L2VMName' in $UsedIpsFile." }
catch { Write-Warning "Could not update used-IPs ledger ($UsedIpsFile): $($_.Exception.Message)" }

# ---- Enable the L2 VFP port and install permissive ACL rules ----
#  The port comes up with VFP loaded but policy NOT enabled (no NC/SLB agent to
#  call it), so rule programming fails with "Error (2)" until we run /enable-port.
#  Enable-VfpPortConnectivity resolves the port, runs /enable-port, then unblocks
#  and installs the ACL rules. It waits (up to PortWaitSeconds) for the port to
#  appear -- no guest ping needed.
if ($EnableVfpConnectivity) {
    # The VFP forwarding extension (vfpext) must be running for port policy to
    # program; if it isn't, vfpctrl fails with "Error (2)". Ensure it first.
    Assert-VfpExtRunning

    Enable-VfpPortConnectivity -VMName $L2VMName `
                               -VfpCtrl $VfpCtrlPath `
                               -LayerName $VfpLayerName `
                               -LayerPriority $VfpLayerPriority `
                               -IncludeIPv6 $VfpIncludeIPv6 `
                               -PortWaitSeconds $VfpPortWaitSeconds
}

try {
    Start-Process -FilePath "vmconnect.exe" -ArgumentList "localhost", $L2VMName -ErrorAction Stop
} catch {
    Write-Host "(vmconnect not available; open Hyper-V Manager to view the console.)"
}

# ---- Add an SSH session to the new L2 VM in MobaXterm ----
# (MobaXterm itself is installed + put on PATH once by Create-L1Vm-Windows.ps1.)
$mobaExe = $null
if ($AddMobaXtermSession) {
    Write-Host "`nAdding MobaXterm SSH session..." -ForegroundColor White
    $mobaExe = Find-MobaXterm
    if ($mobaExe) {
        # A running MobaXterm keeps sessions in memory and OVERWRITES MobaXterm.ini
        # on exit, so a session added now would be lost and never shown. Close the
        # running instance first (gracefully, then force) so our new session both
        # persists and is loaded when we relaunch.
        $running = Get-Process -Name 'MobaXterm*' -ErrorAction SilentlyContinue
        if ($running -and $RestartMobaXtermIfRunning) {
            Write-Host "  MobaXterm is running; closing it so the new session is picked up..." -ForegroundColor Yellow
            foreach ($p in $running) { try { $p.CloseMainWindow() | Out-Null } catch {} }
            Start-Sleep -Seconds 3
            $still = Get-Process -Name 'MobaXterm*' -ErrorAction SilentlyContinue
            foreach ($p in $still) { try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch {} }
            Start-Sleep -Seconds 1
        }

        Add-MobaXtermSession -ExePath $mobaExe -SessionName $L2VMName -SshHost $IPAddress `
                             -Port $MobaXtermSshPort -User $UbuntuUsername -Password $UbuntuPassword
        if ($LaunchMobaXterm) {
            try { Start-Process -FilePath $mobaExe -ErrorAction Stop; Write-Host "  Launched MobaXterm ($mobaExe)." -ForegroundColor Green }
            catch { Write-Host "  MobaXterm session saved; launch it manually: $mobaExe" }
        }
    }
    else { Write-Warning "MobaXterm not found (expected the L1 script to install it under $MobaXtermDir); skipping session creation." }
}

Write-Host ""
Write-Host "==================== L2 Ubuntu VM ====================" -ForegroundColor Green
Write-Host " VM name        : $L2VMName"
Write-Host " Username       : $UbuntuUsername"
Write-Host " Password       : $UbuntuPassword"
Write-Host " IP address     : $IPAddress/$PrefixLength  (gw $gateway, dns $DnsServer)"
Write-Host " Hostname       : $UbuntuHostName    (prompt: $UbuntuUsername@$UbuntuHostName)"
Write-Host " Switch         : $SwitchName"
Write-Host " Source         : Ubuntu cloud image (converted qcow2 -> VHDX)"
Write-Host " First boot     : cloud-init sets user/password, static IP, and installs:"
Write-Host "                  $($ExtraPackages -join ', ')"
Write-Host " No installer   : boots straight into Ubuntu (no ISO, no 'yes' prompt)."
Write-Host " SSH (from L1)  : ssh $UbuntuUsername@$IPAddress   (allow ~1-2 min for cloud-init)"
Write-Host " MobaXterm      : session '$L2VMName' added ($UbuntuUsername@$IPAddress)$(if($mobaExe){' -> '+$mobaExe})"
Write-Host " VFP port       : unblocked + permissive ACLs applied (if VFP present)"
Write-Host "======================================================" -ForegroundColor Green
Write-Host ""
Write-Host "Reminder: internet access also needs host-side NAT on the subnet, e.g.:"
Write-Host "  New-NetNat -Name IntVirtNat -InternalIPInterfaceAddressPrefix $($octets[0]).$($octets[1]).$($octets[2]).0/$PrefixLength"
Write-Host "  (gateway $gateway must live on the L1 host's vSwitch interface)"
Write-Host ""
Write-Host "Reminder: internet access also needs host-side NAT on the subnet, e.g.:"
Write-Host "  New-NetNat -Name IntVirtNat -InternalIPInterfaceAddressPrefix $($octets[0]).$($octets[1]).$($octets[2]).0/$PrefixLength"
Write-Host "  (gateway $gateway must live on the L1 host's vSwitch interface)"
