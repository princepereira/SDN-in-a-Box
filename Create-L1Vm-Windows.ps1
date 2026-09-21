# ============================================================
#  Create-L1Vm-Windows.ps1 : L1 Windows Server VM (L1-GeCurNv-2025)
#  Run in an ELEVATED PowerShell session
#
#  Usage:
#    .\Create-L1Vm-Windows.ps1 -VHDXPath "C:\VHDs\my-image.vhdx" -L1VMName "L1-GeCur-2025"
#    .\Create-L1Vm-Windows.ps1 -RemoteVHDXPath "\\share\path\image.vhdx" -L1VMName "L1-GeCur-2025"
#    .\Create-L1Vm-Windows.ps1 -Branch ge_current_directiof_nv -L1VMName "L1-GeCur-2025"
#
#  NOTE: The Administrator password ($L1VmAdminPassword), locale ($Locale), and
#        time zone ($TimeZone) are constants set near the top of the script.
# ============================================================

[CmdletBinding()]
param(
    # Winbuilds branch name, e.g. ge_current_directiof_nv.
    # When supplied, the LATEST vhdx for the branch is copied from winbuilds.
    # Required unless -VHDXPath is supplied.
    [Parameter(Mandatory = $false)]
    [string]$Branch,

    # Name of the VM to create.
    [Parameter(Mandatory = $false)]
    [string]$L1VMName = "L1-GeCurNv-2025",

    # Explicit path to an existing .vhdx. When set, it is used directly and
    # -Branch is ignored.
    [Parameter(Mandatory = $false)]
    [string]$VHDXPath,

    # Path to a .vhdx (local or on a share) that is first robocopied into
    # C:\VHDs, and the local copy is then used as the base. Takes precedence
    # over -Branch; ignored when -VHDXPath is supplied.
    [Parameter(Mandatory = $false)]
    [string]$RemoteVHDXPath
)

# ---- Static config ----
$vmName        = $L1VMName
$localVhdRoot  = "C:\VHDs"
$winbuildsRoot = "\\winbuilds\release"

# ---- Constants (edit these instead of passing arguments) ----
$L1VmAdminPassword = "Admin@123"           # Administrator password set on first boot
$Locale            = "en-US"               # UI / system / user locale
$TimeZone          = "India Standard Time" # Guest time zone (see: tzutil /l)
$KeyboardLayout    = "0409:00000409"       # Keyboard InputLocale (US English)
$AutoLogonCount    = 1                     # Auto-logon Administrator N times (0 = off)
$ComputerName      = $null                 # Guest hostname (null = derive from VM name)

# ---- Nested virtualization + in-guest SDN/VFP constants ----
$EnableNestedVirtualization = $true
$SkipGuestSetup             = $false
$GuestRolesFeatures         = @(
    'Hyper-V', 'NetworkController', 'NPAS',
    'Containers', 'Telnet-Client', 'NetworkVirtualization'
)
$GuestSwitchName         = 'Ethernet'
$VfpExtensionName        = 'Microsoft Azure VFP Switch Extension'

# ---- Internal NAT switch created INSIDE the L1 guest (for nested L2 VMs) ----
# Mirrors the manual steps:
#   New-VMSwitch -Name IntVirtSwitch -SwitchType Internal
#   New-NetIPAddress -IPAddress 192.168.100.1 -PrefixLength 24 -InterfaceAlias "vEthernet (IntVirtSwitch)"
#   Enable-VMSwitchExtension -VMSwitchName IntVirtSwitch -Name "Microsoft Azure VFP Switch Extension"
#   New-NetNat -Name UbuntuNat -InternalIPInterfaceAddressPrefix 192.168.100.0/24
$CreateInternalSwitch    = $true
$IntSwitchName           = 'IntVirtSwitch'
$IntSwitchGatewayIP      = '192.168.100.1'
$IntSwitchPrefixLength   = 24
$IntSwitchSubnetPrefix   = '192.168.100.0/24'
$IntSwitchNatName        = 'UbuntuNat'
$GuestReadyTimeoutMinutes = 30

# ---- Guest licensing (fixes "server is not properly licensed" / RFM) ----
# Server test/VL images can boot into Reduced Functionality Mode (RFM), which
# makes Install-WindowsFeature refuse EVERY role ("server is not properly
# licensed"). slmgr /rearm only extends a grace timer and does NOT clear RFM on
# an unlicensed VL image, so instead we install the public *generic* KMS-client
# key (GVLK) for the detected edition and best-effort activate. Applying a GVLK
# drops the guest into a licensed grace period even with no KMS reachable, which
# is enough for role installation to proceed. GVLKs are public generic keys, not
# purchased/secret product keys.
$LicenseGuest = $true

# Public GVLKs (KMS client setup keys). Datacenter/Standard for the current
# Windows Server branch (2025 / 26xxx, incl. ge_current_directiof_nv builds).
# The edition is auto-detected in-guest; Datacenter is the default fallback.
$GuestGvlkMap = @{
    'ServerDatacenter' = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'
    'ServerStandard'   = 'TVRH6-WHNXV-R9WG3-9XRFY-MY832'
}
$GuestGvlkDefault = 'D764K-2NDRG-47T6Q-P8T8W-YP6DF'    # Datacenter

# ---- Ubuntu cloud image download (inside the guest, after the vSwitch is ready) ----
# The L2 VM is built from the Ubuntu CLOUD IMAGE (qcow2), not the ISO installer,
# so we pre-stage that .img inside the guest. Create-L2Vm-Linux.ps1 converts it
# to VHDX (qemu-img) and boots it directly with a cloud-init seed.
$DownloadUbuntuImage = $true
$UbuntuImageUrl      = "https://cloud-images.ubuntu.com/releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img"
$UbuntuImageDir      = "C:\ISOs"   # destination folder INSIDE the guest

# ---- MobaXterm (SSH client) install inside the guest ----
# MobaXterm is installed ONCE here (in the L1 guest, where the user runs
# Create-L2Vm-Linux.ps1 and SSHes to the L2 VMs). The L2 script then only ADDS
# a session per VM. We install the portable edition and put a 'mobaxterm'
# launcher on the machine PATH so it can be opened from any directory.
$InstallMobaXterm = $true
$MobaXtermUrl     = 'https://download.mobatek.net/2642026060332702/MobaXterm_Portable_v26.4.zip'
$MobaXtermDir     = 'C:\Tools\MobaXterm'   # portable install location INSIDE the guest
$MobaXtermBinDir  = 'C:\Tools\bin'         # added to PATH; holds a 'mobaxterm' launcher

# ---- Host scripts to copy INTO the guest (after guest setup) ----
$GuestScriptsDir   = "C:\scripts"            # destination folder INSIDE the guest
# Files are resolved relative to THIS script's folder if not absolute.
$HostFilesToCopy   = @('Create-L2Vm-Linux.ps1', 'Enable-VfpPortConnectivity.ps1')

# ---- Helper: find the latest vhdx for a branch on winbuilds ----
# Prefers the Desktop Experience (GUI) Datacenter image and avoids Server Core,
# so -Branch does not accidentally pick a Core (no-GUI) vhdx.
$PreferVhdxIncludePattern = 'serverdatacenter'   # desired SKU substring (case-insensitive)
$PreferVhdxExcludePattern = 'core'               # skip Server Core variants

function Get-LatestWinbuildsVhdx {
    param([string]$Branch)

    $branchPath = Join-Path $winbuildsRoot $Branch
    if (-not (Test-Path $branchPath)) {
        throw "Branch path not found on winbuilds: $branchPath"
    }

    # Iterate build folders newest-first (folder names sort chronologically).
    $buildFolders = Get-ChildItem -Path $branchPath -Directory -ErrorAction Stop |
                    Sort-Object Name -Descending

    foreach ($bf in $buildFolders) {
        # All vhdx files that live under a 'vhdx' path segment, newest first.
        $candidates = Get-ChildItem -Path $bf.FullName -Recurse -Filter *.vhdx -ErrorAction SilentlyContinue |
                      Where-Object { $_.FullName -match '\\vhdx\\' } |
                      Sort-Object LastWriteTime -Descending
        if (-not $candidates) { continue }

        # 1) Prefer Desktop Experience Datacenter (include pattern, NOT Core).
        $preferred = $candidates | Where-Object {
            $_.FullName -match [regex]::Escape($PreferVhdxIncludePattern) -and
            $_.FullName -notmatch [regex]::Escape($PreferVhdxExcludePattern)
        } | Select-Object -First 1
        if ($preferred) {
            Write-Host "Selected Desktop Experience image: $($preferred.FullName)"
            return $preferred
        }

        # 2) Otherwise any non-Core vhdx.
        $nonCore = $candidates | Where-Object { $_.FullName -notmatch [regex]::Escape($PreferVhdxExcludePattern) } |
                   Select-Object -First 1
        if ($nonCore) {
            Write-Host "No '$PreferVhdxIncludePattern' image; using non-Core image: $($nonCore.FullName)"
            return $nonCore
        }

        # 3) Last resort: newest vhdx (may be Server Core).
        $any = $candidates | Select-Object -First 1
        Write-Host "WARNING: only Server Core images found; using: $($any.FullName)"
        return $any
    }
    return $null
}

# ---- Helper: robocopy a vhdx file into C:\VHDs ----
function Copy-VhdxLocally {
    param([System.IO.FileInfo]$VhdxFile)

    # Guard: source path must contain a 'vhdx' segment.
    if ($VhdxFile.FullName -notmatch '\\vhdx\\') {
        throw "Refusing to copy: source path does not contain 'vhdx' -> $($VhdxFile.FullName)"
    }

    if (-not (Test-Path $localVhdRoot)) {
        Write-Host "Creating local VHD directory: $localVhdRoot"
        New-Item -ItemType Directory -Path $localVhdRoot -Force | Out-Null
    }

    $srcDir   = $VhdxFile.DirectoryName
    $fileName = $VhdxFile.Name
    Write-Host "Robocopy: $srcDir\$fileName  ->  $localVhdRoot"

    robocopy $srcDir $localVhdRoot $fileName /Z /J /R:3 /W:5 | Out-Host

    # Robocopy exit codes 0-7 indicate success; 8+ indicate failure.
    if ($LASTEXITCODE -ge 8) {
        throw "Robocopy failed with exit code $LASTEXITCODE"
    }
    $global:LASTEXITCODE = 0

    return (Join-Path $localVhdRoot $fileName)
}

# ---- Helper: robocopy an arbitrary vhdx file (local or share) into C:\VHDs ----
function Copy-RemoteVhdxLocally {
    param([Parameter(Mandatory)][string]$SourcePath)

    if ($SourcePath -notmatch '\.vhdx$') {
        throw "Refusing to copy: -RemoteVHDXPath must point to a .vhdx file -> $SourcePath"
    }
    if (-not (Test-Path $SourcePath)) {
        throw "-RemoteVHDXPath does not exist: $SourcePath"
    }

    if (-not (Test-Path $localVhdRoot)) {
        Write-Host "Creating local VHD directory: $localVhdRoot"
        New-Item -ItemType Directory -Path $localVhdRoot -Force | Out-Null
    }

    $srcItem  = Get-Item -LiteralPath $SourcePath
    $srcDir   = $srcItem.DirectoryName
    $fileName = $srcItem.Name
    $dest     = Join-Path $localVhdRoot $fileName

    # If the source already IS the local copy, no need to robocopy.
    if ([System.IO.Path]::GetFullPath($SourcePath) -ieq [System.IO.Path]::GetFullPath($dest)) {
        Write-Host "-RemoteVHDXPath already resides in $localVhdRoot; using it as-is."
        return $dest
    }

    Write-Host "Robocopy (remote): $srcDir\$fileName  ->  $localVhdRoot"
    robocopy $srcDir $localVhdRoot $fileName /Z /J /R:3 /W:5 | Out-Host

    # Robocopy exit codes 0-7 indicate success; 8+ indicate failure.
    if ($LASTEXITCODE -ge 8) {
        throw "Robocopy failed with exit code $LASTEXITCODE"
    }
    $global:LASTEXITCODE = 0

    return $dest
}
function ConvertTo-XmlSafe {
    param([string]$Text)
    return ($Text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' `
                  -replace '"', '&quot;' -replace "'", '&apos;')
}

# ---- Helper: build an unattend.xml answer file for first-boot automation ----
function New-UnattendXml {
    param(
        [Parameter(Mandatory)][string]$AdminPassword,
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$Locale = "en-US",
        [string]$KeyboardLayout = "0409:00000409",
        [string]$TimeZone = "India Standard Time",
        [int]$AutoLogonCount = 1
    )

    $pwSafe   = ConvertTo-XmlSafe $AdminPassword
    $nameSafe = ConvertTo-XmlSafe $ComputerName
    $tzSafe   = ConvertTo-XmlSafe $TimeZone

    # Optional auto-logon block.
    $autoLogonBlock = ""
    if ($AutoLogonCount -gt 0) {
        $autoLogonBlock = @"
                <AutoLogon>
                    <Password>
                        <Value>$pwSafe</Value>
                        <PlainText>true</PlainText>
                    </Password>
                    <Enabled>true</Enabled>
                    <LogonCount>$AutoLogonCount</LogonCount>
                    <Username>Administrator</Username>
                </AutoLogon>
"@
    }

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
    <settings pass="specialize">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <ComputerName>$nameSafe</ComputerName>
            <TimeZone>$tzSafe</TimeZone>
        </component>
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>$KeyboardLayout</InputLocale>
            <SystemLocale>$Locale</SystemLocale>
            <UILanguage>$Locale</UILanguage>
            <UILanguageFallback>$Locale</UILanguageFallback>
            <UserLocale>$Locale</UserLocale>
        </component>
    </settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <InputLocale>$KeyboardLayout</InputLocale>
            <SystemLocale>$Locale</SystemLocale>
            <UILanguage>$Locale</UILanguage>
            <UILanguageFallback>$Locale</UILanguageFallback>
            <UserLocale>$Locale</UserLocale>
        </component>
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
            <UserAccounts>
                <AdministratorPassword>
                    <Value>$pwSafe</Value>
                    <PlainText>true</PlainText>
                </AdministratorPassword>
            </UserAccounts>
$autoLogonBlock
            <OOBE>
                <HideEULAPage>true</HideEULAPage>
                <HideLocalAccountScreen>true</HideLocalAccountScreen>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <NetworkLocation>Work</NetworkLocation>
                <ProtectYourPC>3</ProtectYourPC>
                <SkipUserOOBE>true</SkipUserOOBE>
                <SkipMachineOOBE>true</SkipMachineOOBE>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>cmd /c reg add "HKLM\SYSTEM\CurrentControlSet\Control\Terminal Server" /v fDenyTSConnections /t REG_DWORD /d 0 /f</CommandLine>
                    <Description>Enable Remote Desktop</Description>
                </SynchronousCommand>
                <SynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <CommandLine>cmd /c netsh advfirewall firewall set rule group="remote desktop" new enable=Yes</CommandLine>
                    <Description>Allow RDP through firewall</Description>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
</unattend>
"@
}

# ---- Helper: inject unattend.xml into a VHDX (mount, write, dismount) ----
function Add-UnattendToVhdx {
    param(
        [Parameter(Mandatory)][string]$VhdxPath,
        [Parameter(Mandatory)][string]$UnattendXml
    )

    Write-Host "Injecting unattend.xml into: $VhdxPath"

    # ---- Ensure the VHDX is free before mounting ----
    # 1) If it is attached to an existing VM, we cannot mount it exclusively.
    $vmDisk = Get-VM -ErrorAction SilentlyContinue |
              Get-VMHardDiskDrive -ErrorAction SilentlyContinue |
              Where-Object { $_.Path -eq $VhdxPath } |
              Select-Object -First 1
    if ($vmDisk) {
        throw ("VHDX is already attached to VM '$($vmDisk.VMName)'. " +
               "Delete/remove that VM (or its disk) first, or point -VHDXPath at a fresh copy.")
    }

    # 2) Clear any stale mount left over from an interrupted run.
    $vhdInfo = Get-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
    if ($vhdInfo -and $vhdInfo.Attached) {
        Write-Host "VHDX is currently mounted; dismounting stale mount..."
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
    }

    $mounted = Mount-VHD -Path $VhdxPath -PassThru -ErrorAction Stop
    try {
        $disk = $mounted | Get-Disk

        # Locate the Windows partition (the one containing \Windows).
        $winDrive = $null
        foreach ($p in (Get-Partition -DiskNumber $disk.Number | Where-Object DriveLetter)) {
            if (Test-Path "$($p.DriveLetter):\Windows\System32") {
                $winDrive = "$($p.DriveLetter):"
                break
            }
        }
        if (-not $winDrive) {
            throw "Could not locate the Windows partition inside the VHDX."
        }

        $pantherDir  = Join-Path $winDrive "Windows\Panther"
        $unattendDst = Join-Path $pantherDir "unattend.xml"
        if (-not (Test-Path $pantherDir)) {
            New-Item -ItemType Directory -Path $pantherDir -Force | Out-Null
        }

        # Write as UTF-8 without BOM.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($unattendDst, $UnattendXml, $utf8NoBom)
        Write-Host "Wrote answer file: $unattendDst"
    }
    finally {
        Dismount-VHD -Path $VhdxPath -ErrorAction SilentlyContinue
    }
}

# ---- Helper: wait until the guest is reachable via PowerShell Direct ----
function Wait-GuestReady {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [int]$TimeoutMinutes = 30,
        # A single successful probe is NOT enough: right after first boot (or a
        # licensing/servicing reboot) the guest can answer PowerShell Direct while
        # a reboot is still queued, which makes Install-WindowsFeature fail with
        # "A system shutdown is in progress" and then "not in running state".
        # Require the guest to be settled: host-side Running, a minimum uptime,
        # and several consecutive good probes so an in-progress reboot resets us.
        [int]$StableProbes = 3,
        [int]$ProbeIntervalSeconds = 15,
        [int]$MinUptimeSeconds = 45
    )
    Write-Host "Waiting for guest '$VMName' to become reachable and settled via PowerShell Direct (up to $TimeoutMinutes min)..."
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $consecutive = 0
    while ((Get-Date) -lt $deadline) {
        $ok = $false
        try {
            # Host-side: the VM must actually be Running (not mid-reboot / off).
            $vm = Get-VM -Name $VMName -ErrorAction Stop
            if ($vm.State -eq 'Running') {
                $uptime = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
                    ((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds
                } -ErrorAction Stop
                if ($uptime -ge $MinUptimeSeconds) { $ok = $true }
            }
        }
        catch { $ok = $false }

        if ($ok) {
            $consecutive++
            if ($consecutive -ge $StableProbes) {
                Write-Host "Guest is reachable and settled."
                return $true
            }
        }
        else {
            $consecutive = 0
        }
        Start-Sleep -Seconds $ProbeIntervalSeconds
    }
    return $false
}

# ---- Helper: copy host files into the guest via PowerShell Direct ----
function Copy-FilesToGuest {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string[]]$HostFiles,
        [string]$GuestDir = 'C:\Scripts',
        [string]$ScriptRoot = ''
    )

    # Resolve each source path (relative paths are anchored to the script folder).
    $resolved = @()
    foreach ($f in $HostFiles) {
        $p = $f
        if (-not [System.IO.Path]::IsPathRooted($p) -and $ScriptRoot) {
            $p = Join-Path $ScriptRoot $f
        }
        if (Test-Path $p) { $resolved += (Get-Item -LiteralPath $p).FullName }
        else { Write-Host "  WARNING: host file not found, skipping: $p" }
    }
    if (-not $resolved) { Write-Host "  No host files to copy."; return }

    $session = New-PSSession -VMName $VMName -Credential $Credential -ErrorAction Stop
    try {
        Invoke-Command -Session $session -ScriptBlock {
            param($dir)
            if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        } -ArgumentList $GuestDir

        foreach ($src in $resolved) {
            $dest = Join-Path $GuestDir ([System.IO.Path]::GetFileName($src))
            Copy-Item -Path $src -Destination $dest -ToSession $session -Force -ErrorAction Stop
            Write-Host "  Copied to guest: $dest"
        }
    }
    finally {
        Remove-PSSession $session -ErrorAction SilentlyContinue
    }
}

# ---- Helper: in-guest SDN role/feature install + VFP switch extension ----
function Invoke-GuestSdnSetup {
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][pscredential]$Credential,
        [Parameter(Mandatory)][string[]]$RolesFeatures,
        [string]$GuestSwitchName = 'Ethernet',
        [string]$VfpExtensionName = 'Microsoft Azure VFP Switch Extension',
        [bool]$CreateInternalSwitch = $true,
        [string]$IntSwitchName = 'IntVirtSwitch',
        [string]$IntSwitchGatewayIP = '192.168.100.1',
        [int]$IntSwitchPrefixLength = 24,
        [string]$IntSwitchSubnetPrefix = '192.168.100.0/24',
        [string]$IntSwitchNatName = 'UbuntuNat',
        [int]$ReadyTimeoutMinutes = 30,
        [bool]$LicenseGuest = $true,
        [hashtable]$GvlkMap = @{},
        [string]$GvlkDefault = '',
        [bool]$DownloadUbuntuImage = $false,
        [string]$UbuntuImageUrl = '',
        [string]$UbuntuImageDir = 'C:\ISOs',
        [bool]$InstallMobaXterm = $false,
        [string]$MobaXtermUrl = '',
        [string]$MobaXtermDir = 'C:\Tools\MobaXterm',
        [string]$MobaXtermBinDir = 'C:\Tools\bin'
    )

    if (-not (Wait-GuestReady -VMName $VMName -Credential $Credential -TimeoutMinutes $ReadyTimeoutMinutes)) {
        throw "Guest '$VMName' did not become reachable within $ReadyTimeoutMinutes minutes."
    }

    # ---- Ensure the guest is Licensed (test/VL images can boot into RFM) ----
    # Install-WindowsFeature refuses on an unlicensed server. Apply the edition's
    # public GVLK (KMS client key) + best-effort activate; this clears RFM into a
    # licensed grace period even when no KMS is reachable.
    if ($LicenseGuest) {
        Write-Host "Checking guest licensing state..."
        $lic = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            param($gvlkMap, $gvlkDefault)

            function Get-LicStatus {
                $p = Get-CimInstance SoftwareLicensingProduct -ErrorAction SilentlyContinue |
                     Where-Object { $_.PartialProductKey -and $_.ApplicationId -eq '55c92734-d682-4d71-983e-d6ec3f16059f' } |
                     Select-Object -First 1
                if ($p) { $p.LicenseStatus } else { $null }   # 1 = Licensed
            }

            $msg = @()
            $status = Get-LicStatus
            $changed = $false

            if ($status -eq 1) {
                $msg += "Guest already Licensed."
            }
            else {
                # Detect edition to pick the correct GVLK (Datacenter vs Standard).
                $edition = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).EditionID
                $gvlk = $null
                if ($edition -and $gvlkMap.ContainsKey($edition)) { $gvlk = $gvlkMap[$edition] }
                elseif ($gvlkDefault) { $gvlk = $gvlkDefault }

                $msg += "License status = $status (not Licensed). EditionID=$edition."
                if ($gvlk) {
                    $slmgr = "$env:windir\System32\slmgr.vbs"
                    $msg += "Installing GVLK $gvlk ..."
                    $ipk = & cscript.exe //nologo $slmgr /ipk $gvlk 2>&1
                    $msg += ($ipk | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
                    Start-Sleep -Seconds 3
                    $msg += "Attempting activation (slmgr /ato, best-effort)..."
                    $ato = & cscript.exe //nologo $slmgr /ato 2>&1
                    $msg += ($ato | Where-Object { $_ -match '\S' } | Select-Object -Last 1)
                    Start-Sleep -Seconds 3
                    $changed = $true
                }
                else {
                    $msg += "No GVLK available for edition '$edition'; cannot auto-license."
                }
            }

            $newStatus = Get-LicStatus
            [pscustomobject]@{
                Status    = $status
                NewStatus = $newStatus
                Changed   = $changed
                Messages  = $msg
            }
        } -ArgumentList $GvlkMap, $GvlkDefault

        $lic.Messages | ForEach-Object { if ($_) { Write-Host "  $_" } }
        if ($lic.NewStatus -eq 1) {
            Write-Host "  Guest is now Licensed."
        }
        elseif ($lic.Changed) {
            Write-Host "  GVLK applied; guest is in a licensed grace period (activation not confirmed). Proceeding with role install."
        }
        else {
            Write-Warning "Guest is still not Licensed; role installation may fail. Ensure a KMS is reachable or apply a valid key."
        }

        # A licensing state change can require a reboot to fully take effect.
        if ($lic.Changed) {
            Write-Host "Rebooting guest to apply licensing change..."
            Invoke-Command -VMName $VMName -Credential $Credential `
                           -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 20
            if (-not (Wait-GuestReady -VMName $VMName -Credential $Credential -TimeoutMinutes $ReadyTimeoutMinutes)) {
                throw "Guest did not come back after the licensing reboot."
            }
        }
    }

    # ---- Install roles/features (each attempted independently, with retry) ----
    # Even after Wait-GuestReady, a queued servicing reboot can fire mid-install
    # and yield "A system shutdown is in progress" / "not in running state".
    # Treat those as transient: wait for the guest to settle and retry only the
    # roles that are not yet installed, up to a few attempts.
    Write-Host "Installing roles/features inside the guest..."
    $pending = @($RolesFeatures)
    $need = $false
    $maxAttempts = 4
    for ($attempt = 1; $attempt -le $maxAttempts -and $pending.Count -gt 0; $attempt++) {
        if ($attempt -gt 1) {
            Write-Host "  Transient failure(s) detected; waiting for guest to settle and retrying (attempt $attempt/$maxAttempts)..."
            if (-not (Wait-GuestReady -VMName $VMName -Credential $Credential -TimeoutMinutes $ReadyTimeoutMinutes)) {
                throw "Guest did not become reachable while retrying role installation."
            }
        }

        $install = $null
        try {
            $install = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
                param($features)
                $done = @(); $failed = @(); $transient = @(); $need = $false
                foreach ($f in $features) {
                    try {
                        $r = Install-WindowsFeature -Name $f -IncludeManagementTools -ErrorAction Stop
                        if ($r.Success) {
                            $done += $f
                            if ($r.RestartNeeded -eq 'Yes') { $need = $true }
                        }
                        else { $failed += "FAILED:    $f" }
                    }
                    catch {
                        $m = $_.Exception.Message
                        if ($m -match 'shutdown is in progress|not in running state|being shut down') {
                            $transient += $f
                        }
                        else { $failed += "SKIPPED:   $f -> $m" }
                    }
                }
                [pscustomobject]@{ Done = $done; Failed = $failed; Transient = $transient; RestartNeeded = $need }
            } -ArgumentList (, $pending)
        }
        catch {
            # The whole invoke failed (e.g. VM left Running mid-batch): retry all.
            Write-Host "  Role install invocation failed transiently: $($_.Exception.Message)"
            continue
        }

        foreach ($d in $install.Done)   { Write-Host "  Installed: $d" }
        foreach ($fm in $install.Failed) { Write-Host "  $fm" }
        if ($install.RestartNeeded) { $need = $true }

        # Only genuinely-transient roles are retried; hard failures are dropped.
        $pending = @($install.Transient)
        foreach ($t in $pending) { Write-Host "  RETRY:     $t (a system shutdown was in progress)" }
    }
    if ($pending.Count -gt 0) {
        throw "Roles still not installed after $maxAttempts attempts (guest kept rebooting): $($pending -join ', ')"
    }

    # ---- Reboot the guest if any feature requires it (Hyper-V does) ----
    if ($need) {
        Write-Host "Guest requires a restart to finish role installation. Rebooting..."
        Invoke-Command -VMName $VMName -Credential $Credential `
                       -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 20
        if (-not (Wait-GuestReady -VMName $VMName -Credential $Credential -TimeoutMinutes $ReadyTimeoutMinutes)) {
            throw "Guest did not come back after the post-install reboot."
        }
    }

    # ---- Create the guest external vSwitch and enable the VFP extension ----
    Write-Host "Configuring guest vSwitch '$GuestSwitchName' and VFP extension..."
    $vfp = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
        param($switchName, $vfpName)
        Import-Module Hyper-V -ErrorAction SilentlyContinue
        $out = @()

        # Hyper-V PowerShell module must be present (role installed successfully).
        if (-not (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue)) {
            $out += "Hyper-V PowerShell module not available in guest (Hyper-V role not installed); skipping vSwitch/VFP setup."
            return $out
        }

        $eth = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
               Where-Object { $_.Status -eq 'Up' } |
               Sort-Object -Property LinkSpeed -Descending |
               Select-Object -First 1
        if (-not $eth) { return @("No 'Up' physical adapter found in guest; cannot create vSwitch.") }

        # The Virtual Machine Management Service (vmms) may still be starting right
        # after the role-install reboot. Touching switches before it is Running
        # fails with "object not found / verify the VMMS is running". Wait for it.
        $svc = Get-Service vmms -ErrorAction SilentlyContinue
        if ($svc) {
            if ($svc.Status -ne 'Running') { try { Start-Service vmms -ErrorAction SilentlyContinue } catch {} }
            $deadline = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $deadline) {
                try { $svc.Refresh() } catch {}
                if ($svc.Status -eq 'Running') { break }
                Start-Sleep -Seconds 3
            }
            $out += "VMMS service status: $($svc.Status)."
        }

        if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) {
            $out += "vSwitch '$switchName' already exists."
        }
        else {
            # New-VMSwitch can still fail transiently right after the reboot; retry.
            $created = $false
            for ($i = 1; $i -le 6 -and -not $created; $i++) {
                try {
                    New-VMSwitch -Name $switchName -NetAdapterName $eth.Name -AllowManagementOS $true -ErrorAction Stop | Out-Null
                    $created = $true
                }
                catch {
                    if ($i -eq 6) { $out += "New-VMSwitch attempt $i failed: $($_.Exception.Message)" }
                    else { Start-Sleep -Seconds 5 }
                }
            }
            # Only claim success if the switch actually exists now.
            if (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue) {
                $out += "Created external vSwitch '$switchName' on '$($eth.Name)'."
            }
            else {
                return ($out + "vSwitch '$switchName' could NOT be created; skipping VFP setup.")
            }
        }

        if (-not (Get-Command Get-VMSystemSwitchExtension -ErrorAction SilentlyContinue)) {
            $out += "Get-VMSystemSwitchExtension unavailable; cannot check/enable VFP extension."
            return $out
        }
        $available = Get-VMSystemSwitchExtension -ErrorAction SilentlyContinue |
                     Where-Object { $_.Name -eq $vfpName }
        if (-not $available) {
            $out += "VFP extension '$vfpName' is NOT registered on this build; skipping enable."
            return $out
        }

        $enabled = [bool](Get-VMSwitchExtension -VMSwitchName $switchName -Name $vfpName -ErrorAction SilentlyContinue).Enabled
        for ($i = 1; $i -le 5 -and -not $enabled; $i++) {
            try { Enable-VMSwitchExtension -VMSwitchName $switchName -Name $vfpName -ErrorAction Stop | Out-Null } catch {}
            Start-Sleep -Seconds 3
            $enabled = [bool](Get-VMSwitchExtension -VMSwitchName $switchName -Name $vfpName -ErrorAction SilentlyContinue).Enabled
        }
        $out += "VFP extension '$vfpName' Enabled=$enabled on switch '$switchName'."
        return $out
    } -ArgumentList $GuestSwitchName, $VfpExtensionName

    $vfp | ForEach-Object { Write-Host "  $_" }

    # ---- Reboot the guest so the VFP forwarding extension (vfpext) actually loads ----
    #  After the external vSwitch is created and the VFP extension is enabled, the
    #  vfpext driver is registered but NOT yet running on the live stack. Until the
    #  node reboots, vfpctrl on the resulting L2 ports fails ("Error (2)") and rules
    #  cannot be programmed. Restart the node here, wait for it to come back, THEN
    #  create the internal switch so VFP is live for the nested L2 ports.
    Write-Host "Restarting the guest so the VFP extension (vfpext) starts before internal-switch creation..."
    Invoke-Command -VMName $VMName -Credential $Credential `
                   -ScriptBlock { Restart-Computer -Force } -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 20
    if (-not (Wait-GuestReady -VMName $VMName -Credential $Credential -TimeoutMinutes $ReadyTimeoutMinutes)) {
        throw "Guest did not come back after the pre-internal-switch (VFP) reboot."
    }
    Write-Host "Guest is back up; VFP extension should now be running. Proceeding with internal switch creation."

    # ---- Create the INTERNAL NAT switch inside the guest (for nested L2 VMs) ----
    if ($CreateInternalSwitch) {
        Write-Host "Creating internal NAT switch '$IntSwitchName' ($IntSwitchSubnetPrefix) inside the guest..."
        $intr = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            param($name, $gwIp, $prefix, $subnet, $natName, $vfpName)
            Import-Module Hyper-V -ErrorAction SilentlyContinue
            $out = @()

            if (-not (Get-Command New-VMSwitch -ErrorAction SilentlyContinue)) {
                return @("Hyper-V module not available; skipping internal switch '$name'.")
            }

            # 1. Internal switch.
            if (-not (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue)) {
                try { New-VMSwitch -Name $name -SwitchType Internal -ErrorAction Stop | Out-Null; $out += "Created internal switch '$name'." }
                catch { return ($out + "Failed to create internal switch '$name': $($_.Exception.Message)") }
            }
            else { $out += "Internal switch '$name' already exists." }

            # 2. Gateway IP on the host vNIC.
            $alias = "vEthernet ($name)"
            $deadline = (Get-Date).AddSeconds(30)
            while (-not (Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
            if (-not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress $gwIp -ErrorAction SilentlyContinue)) {
                try { New-NetIPAddress -InterfaceAlias $alias -IPAddress $gwIp -PrefixLength $prefix -ErrorAction Stop | Out-Null; $out += "Assigned gateway $gwIp/$prefix to '$alias'." }
                catch { $out += "Could not assign $gwIp/$prefix to '$alias': $($_.Exception.Message)" }
            }
            else { $out += "Gateway $gwIp already present on '$alias'." }

            # 3. Enable the VFP extension on the internal switch (fail-closed L2 ports).
            #    Enabling right after New-VMSwitch can silently not stick, so verify
            #    Enabled=True and retry a few times.
            try {
                $ext = Get-VMSwitchExtension -VMSwitchName $name -Name $vfpName -ErrorAction SilentlyContinue
                if ($ext) {
                    $enabled = [bool]$ext.Enabled
                    for ($i = 1; $i -le 5 -and -not $enabled; $i++) {
                        try { Enable-VMSwitchExtension -VMSwitchName $name -Name $vfpName -ErrorAction Stop | Out-Null } catch {}
                        Start-Sleep -Seconds 3
                        $enabled = [bool](Get-VMSwitchExtension -VMSwitchName $name -Name $vfpName -ErrorAction SilentlyContinue).Enabled
                    }
                    if ($enabled) { $out += "VFP extension enabled on '$name' (verified)." }
                    else { $out += "WARNING: VFP extension on '$name' still NOT enabled after retries; run: Enable-VMSwitchExtension -VMSwitchName $name -Name '$vfpName'" }
                }
                else { $out += "VFP extension '$vfpName' not available on this build; skipping enable on '$name'." }
            }
            catch { $out += "Could not enable VFP extension on '$name': $($_.Exception.Message)" }

            # 4. NAT for the subnet.
            $natForSubnet = Get-NetNat -ErrorAction SilentlyContinue | Where-Object { $_.InternalIPInterfaceAddressPrefix -eq $subnet }
            if (-not $natForSubnet) {
                $useName = $natName
                if (Get-NetNat -Name $useName -ErrorAction SilentlyContinue) { $useName = "$natName-$($subnet -replace '[./]','-')" }
                try { New-NetNat -Name $useName -InternalIPInterfaceAddressPrefix $subnet -ErrorAction Stop | Out-Null; $out += "Created NAT '$useName' for $subnet." }
                catch { $out += "Could not create NAT for $subnet : $($_.Exception.Message)" }
            }
            else { $out += "NAT already present for $subnet ('$($natForSubnet.Name)')." }

            # 5. Allow inbound ICMP echo on the host so the L2 guests can ping the
            #    gateway (192.168.100.1). Windows Firewall drops unsolicited inbound
            #    ICMP by default, which is why L1->L2 works but L2->L1 gateway fails.
            foreach ($fw in @(
                @{ Name = 'Allow ICMPv4-In (IntVirtSwitch)'; Proto = 'ICMPv4'; Icmp = 8   },
                @{ Name = 'Allow ICMPv6-In (IntVirtSwitch)'; Proto = 'ICMPv6'; Icmp = 128 }
            )) {
                try {
                    if (-not (Get-NetFirewallRule -DisplayName $fw.Name -ErrorAction SilentlyContinue)) {
                        New-NetFirewallRule -DisplayName $fw.Name -Protocol $fw.Proto -IcmpType $fw.Icmp `
                            -Direction Inbound -Action Allow -Profile Any -ErrorAction Stop | Out-Null
                        $out += "Added firewall rule '$($fw.Name)'."
                    } else { $out += "Firewall rule '$($fw.Name)' already present." }
                } catch { $out += "Could not add firewall rule '$($fw.Name)': $($_.Exception.Message)" }
            }

            return $out
        } -ArgumentList $IntSwitchName, $IntSwitchGatewayIP, $IntSwitchPrefixLength, $IntSwitchSubnetPrefix, $IntSwitchNatName, $VfpExtensionName

        $intr | ForEach-Object { Write-Host "  $_" }
    }

    # ---- Download the Ubuntu cloud image INSIDE the guest (vSwitch is now ready) ----
    if ($DownloadUbuntuImage -and $UbuntuImageUrl) {
        Write-Host "Downloading Ubuntu cloud image inside the guest from $UbuntuImageUrl ..."
        $img = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            param($url, $dir)
            $out = @()
            try {
                if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                $dest = Join-Path $dir ([System.IO.Path]::GetFileName($url))
                if (Test-Path $dest) {
                    $out += "Cloud image already present: $dest (skipping download)."
                    return $out
                }
                $ProgressPreference = 'SilentlyContinue'          # faster Invoke-WebRequest
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing -ErrorAction Stop
                $sizeMB = [math]::Round((Get-Item $dest).Length / 1MB, 1)
                $out += "Downloaded cloud image: $dest ($sizeMB MB)."
            }
            catch { $out += "FAILED to download cloud image from $url -> $($_.Exception.Message)" }
            return $out
        } -ArgumentList $UbuntuImageUrl, $UbuntuImageDir

        $img | ForEach-Object { Write-Host "  $_" }
    }

    # ---- Install MobaXterm (portable) INSIDE the guest + put it on PATH ----
    # Done once here so the L2 script only has to add a session per VM.
    if ($InstallMobaXterm -and $MobaXtermUrl) {
        Write-Host "Installing MobaXterm inside the guest from $MobaXtermUrl ..."
        $moba = Invoke-Command -VMName $VMName -Credential $Credential -ScriptBlock {
            param($url, $dir, $binDir)
            $out = @()
            try {
                $ProgressPreference = 'SilentlyContinue'
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

                $exe = Get-ChildItem -Path $dir -Filter 'MobaXterm*.exe' -Recurse -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -notmatch 'Uninstall' } | Select-Object -First 1
                if (-not $exe) {
                    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
                    $zip = Join-Path $env:TEMP 'MobaXterm_Portable.zip'
                    Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing -ErrorAction Stop
                    Expand-Archive -Path $zip -DestinationPath $dir -Force
                    Remove-Item $zip -Force -ErrorAction SilentlyContinue
                    $exe = Get-ChildItem -Path $dir -Filter 'MobaXterm*.exe' -Recurse -ErrorAction SilentlyContinue |
                           Where-Object { $_.Name -notmatch 'Uninstall' } | Select-Object -First 1
                    $out += "Installed MobaXterm portable: $($exe.FullName)"
                }
                else {
                    $out += "MobaXterm already present: $($exe.FullName) (skipping download)."
                }

                if ($exe) {
                    # Create a 'mobaxterm' launcher on the machine PATH.
                    if (-not (Test-Path $binDir)) { New-Item -ItemType Directory -Path $binDir -Force | Out-Null }
                    $shim = Join-Path $binDir 'mobaxterm.cmd'
                    Set-Content -Path $shim -Value ("@echo off`r`nstart """" ""$($exe.FullName)"" %*") -Encoding ASCII

                    $machinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine')
                    if (-not $machinePath) { $machinePath = '' }
                    $parts = $machinePath.Split(';') | Where-Object { $_ -ne '' }
                    if ($parts -notcontains $binDir) {
                        [Environment]::SetEnvironmentVariable('Path', ((@($parts) + $binDir) -join ';'), 'Machine')
                        $out += "Added '$binDir' to machine PATH (open a NEW shell to use 'mobaxterm')."
                    }
                    $out += "'mobaxterm' launcher ready: $shim"
                }
                else { $out += "FAILED: MobaXterm.exe not found after extracting $url" }
            }
            catch { $out += "FAILED to install MobaXterm from $url -> $($_.Exception.Message)" }
            return $out
        } -ArgumentList $MobaXtermUrl, $MobaXtermDir, $MobaXtermBinDir

        $moba | ForEach-Object { Write-Host "  $_" }
    }
}

# ---- Guard: fail early if the target VM already exists ----
if (Get-VM -Name $vmName -ErrorAction SilentlyContinue) {
    throw ("A VM named '$vmName' already exists. Remove it first " +
           "(Stop-VM -Name '$vmName' -TurnOff; Remove-VM -Name '$vmName' -Force), " +
           "or choose a different -L1VMName.")
}

# ---- Resolve the VHDX to use ----
$resolvedVhdx = $null

if ($VHDXPath) {
    # Explicit path wins: ignore -Branch.
    if (-not (Test-Path $VHDXPath)) {
        throw "Specified -VHDXPath does not exist: $VHDXPath"
    }
    Write-Host "Using explicitly provided VHDX: $VHDXPath"
    $resolvedVhdx = $VHDXPath
}
elseif ($RemoteVHDXPath) {
    # Robocopy the given vhdx into C:\VHDs, then use the local copy as the base.
    Write-Host "Copying -RemoteVHDXPath into $localVhdRoot ..."
    $resolvedVhdx = Copy-RemoteVhdxLocally -SourcePath $RemoteVHDXPath
}
elseif ($Branch) {
    # Always copy the LATEST vhdx for the branch from winbuilds.
    Write-Host "Fetching latest vhdx for branch '$Branch' from winbuilds..."
    $latest = Get-LatestWinbuildsVhdx -Branch $Branch
    if (-not $latest) { throw "No vhdx found on winbuilds for branch '$Branch'." }
    $resolvedVhdx = Copy-VhdxLocally -VhdxFile $latest
}
else {
    throw "Provide either -VHDXPath, -RemoteVHDXPath, or -Branch."
}

if (-not (Test-Path $resolvedVhdx)) {
    throw "Resolved vhdx path does not exist: $resolvedVhdx"
}
Write-Host "Using base VHDX (kept read-only, reusable): $resolvedVhdx"

# ---- Create a per-VM differencing disk so the base image is never locked ----
# The base VHDX becomes the read-only parent; all writes (including the injected
# unattend.xml and the guest's first boot) go into this child. Multiple VMs can
# therefore share the same base image concurrently.
$vmDiskDir = Join-Path $localVhdRoot $vmName
if (-not (Test-Path $vmDiskDir)) {
    New-Item -ItemType Directory -Path $vmDiskDir -Force | Out-Null
}
$vmVhdx = Join-Path $vmDiskDir "$vmName.vhdx"

# Remove a stale child from a previous run (dismount first if needed).
if (Test-Path $vmVhdx) {
    $stale = Get-VHD -Path $vmVhdx -ErrorAction SilentlyContinue
    if ($stale -and $stale.Attached) { Dismount-VHD -Path $vmVhdx -ErrorAction SilentlyContinue }
    Remove-Item -Path $vmVhdx -Force
}

# ---- Make sure the base VHDX is not held by another process ------------------
# 'New-VHD -Differencing' opens the parent read-only; if the base is still
# mounted, or is directly attached to an existing VM (e.g. from an earlier run
# of an older version of this script), it fails with 0x80070020 (file in use).
# Release a leftover mount automatically, and give an actionable error if a VM
# is holding the base directly.
$baseVhd = Get-VHD -Path $resolvedVhdx -ErrorAction SilentlyContinue
if ($baseVhd -and $baseVhd.Attached) {
    Write-Host "Base VHDX is mounted; dismounting it so it can be reused read-only..."
    Dismount-VHD -Path $resolvedVhdx -ErrorAction SilentlyContinue
}

$baseHolders = @()
foreach ($vm in (Get-VM -ErrorAction SilentlyContinue)) {
    foreach ($hd in (Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue)) {
        if ($hd.Path -eq $resolvedVhdx) {
            $baseHolders += [pscustomobject]@{ VM = $vm.Name; State = $vm.State }
        }
    }
}
if ($baseHolders.Count -gt 0) {
    $list = ($baseHolders | ForEach-Object { "$($_.VM) [$($_.State)]" }) -join ', '
    throw @"
The base VHDX is directly attached to an existing VM and cannot be used as a
read-only parent: $list

This is a leftover from an earlier run that attached the base directly. Detach
or remove that VM, then re-run. For example:

    Stop-VM '$($baseHolders[0].VM)' -TurnOff -Force -ErrorAction SilentlyContinue
    Remove-VM '$($baseHolders[0].VM)' -Force
    Dismount-VHD -Path '$resolvedVhdx' -ErrorAction SilentlyContinue
"@
}

Write-Host "Creating per-VM differencing disk: $vmVhdx"
New-VHD -Path $vmVhdx -ParentPath $resolvedVhdx -Differencing -ErrorAction Stop | Out-Null

# ---- Inject unattend.xml for hands-free first boot (into the CHILD disk) ----
if ($L1VmAdminPassword) {
    if (-not $ComputerName) {
        # Computer names are limited to 15 characters.
        $ComputerName = ($vmName -replace '[^A-Za-z0-9-]', '')
        if ($ComputerName.Length -gt 15) { $ComputerName = $ComputerName.Substring(0, 15) }
    }
    Write-Host "Preparing unattend.xml (ComputerName=$ComputerName, Locale=$Locale, TimeZone=$TimeZone)..."
    $unattend = New-UnattendXml -AdminPassword $L1VmAdminPassword `
                                -ComputerName $ComputerName `
                                -Locale $Locale `
                                -KeyboardLayout $KeyboardLayout `
                                -TimeZone $TimeZone `
                                -AutoLogonCount $AutoLogonCount
    Add-UnattendToVhdx -VhdxPath $vmVhdx -UnattendXml $unattend
}
else {
    Write-Host "`$L1VmAdminPassword is empty; skipping unattend.xml injection (manual first-boot setup)."
}

# ---- Use the existing External virtual switch (create one if none exists) ----
$switchName = (Get-VMSwitch | Where-Object SwitchType -eq 'External' | Select-Object -First 1).Name
if (-not $switchName) {
    Write-Host "No External virtual switch found. Creating one..."

    # Pick an active, physical, non-virtual network adapter to bind to.
    $netAdapter = Get-NetAdapter -Physical -ErrorAction Stop |
                  Where-Object { $_.Status -eq 'Up' -and $_.Virtual -eq $false } |
                  Sort-Object -Property LinkSpeed -Descending |
                  Select-Object -First 1
    if (-not $netAdapter) {
        throw "No active physical network adapter found to create an External switch."
    }

    $switchName = "External virtual Switch"
    Write-Host "Creating External switch '$switchName' bound to '$($netAdapter.Name)'..."
    New-VMSwitch -Name $switchName `
                 -NetAdapterName $netAdapter.Name `
                 -AllowManagementOS $true | Out-Null
}
Write-Host "Using External switch: $switchName"

# ---- 1. Create the VM (Gen 2, 16 GB RAM, existing VHDX, external switch) ----
New-VM -Name $vmName `
       -Generation 2 `
       -MemoryStartupBytes 16GB `
       -VHDPath $vmVhdx `
       -SwitchName $switchName

# ---- Disable Dynamic Memory (static 16 GB) ----
Set-VMMemory -VMName $vmName -DynamicMemoryEnabled $false -StartupBytes 16GB

# ---- 2. Allow Enhanced Session Mode (host-level policy) ----
Set-VMHost -EnableEnhancedSessionMode $true

# ---- 3. Disable Secure Boot (Security settings) ----
Set-VMFirmware -VMName $vmName -EnableSecureBoot Off

# ---- 4. Set number of virtual processors to 8 ----
Set-VMProcessor -VMName $vmName -Count 8

# ---- 5. Enable Nested Virtualization on the host (VM must be OFF) ----
if ($EnableNestedVirtualization) {
    Write-Host "Enabling nested virtualization (ExposeVirtualizationExtensions) on '$vmName'..."
    Set-VMProcessor -VMName $vmName -ExposeVirtualizationExtensions $true
    # Nested guests need MAC spoofing so their child VMs' traffic is not filtered.
    Set-VMNetworkAdapter -VMName $vmName -MacAddressSpoofing On
}

# ---- Verify settings ----
Get-VM -Name $vmName | Format-List Name, Generation, State
Get-VMMemory -VMName $vmName | Format-List DynamicMemoryEnabled, Startup
Get-VMFirmware -VMName $vmName | Format-List SecureBoot
Get-VMProcessor -VMName $vmName | Format-List Count, ExposeVirtualizationExtensions
Get-VMNetworkAdapter -VMName $vmName | Format-List Name, SwitchName, MacAddressSpoofing

# ---- Start the VM ----
Write-Host "Starting VM '$vmName'..."
Start-VM -Name $vmName

# ---- In-guest SDN/VFP configuration via PowerShell Direct ----
# Requires the Administrator credential set by the unattend answer file.
if ($L1VmAdminPassword -and -not $SkipGuestSetup) {
    $securePw  = ConvertTo-SecureString $L1VmAdminPassword -AsPlainText -Force
    $guestCred = New-Object System.Management.Automation.PSCredential("Administrator", $securePw)

    Invoke-GuestSdnSetup -VMName $vmName `
                         -Credential $guestCred `
                         -RolesFeatures $GuestRolesFeatures `
                         -GuestSwitchName $GuestSwitchName `
                         -VfpExtensionName $VfpExtensionName `
                         -CreateInternalSwitch $CreateInternalSwitch `
                         -IntSwitchName $IntSwitchName `
                         -IntSwitchGatewayIP $IntSwitchGatewayIP `
                         -IntSwitchPrefixLength $IntSwitchPrefixLength `
                         -IntSwitchSubnetPrefix $IntSwitchSubnetPrefix `
                         -IntSwitchNatName $IntSwitchNatName `
                         -ReadyTimeoutMinutes $GuestReadyTimeoutMinutes `
                         -LicenseGuest $LicenseGuest `
                         -GvlkMap $GuestGvlkMap `
                         -GvlkDefault $GuestGvlkDefault `
                         -DownloadUbuntuImage $DownloadUbuntuImage `
                         -UbuntuImageUrl $UbuntuImageUrl `
                         -UbuntuImageDir $UbuntuImageDir `
                         -InstallMobaXterm $InstallMobaXterm `
                         -MobaXtermUrl $MobaXtermUrl `
                         -MobaXtermDir $MobaXtermDir `
                         -MobaXtermBinDir $MobaXtermBinDir

    Write-Host "Guest SDN/VFP configuration complete."

    # ---- Copy host helper scripts into the guest (e.g. Create-L2Vm-Linux.ps1) ----
    if ($HostFilesToCopy -and $HostFilesToCopy.Count -gt 0) {
        $scriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
        Write-Host "Copying host files into guest '$GuestScriptsDir'..."
        Copy-FilesToGuest -VMName $vmName `
                          -Credential $guestCred `
                          -HostFiles $HostFilesToCopy `
                          -GuestDir $GuestScriptsDir `
                          -ScriptRoot $scriptRoot
    }
}
elseif ($SkipGuestSetup) {
    Write-Host "-SkipGuestSetup specified; skipping in-guest role/feature and VFP configuration."
}
else {
    Write-Host "`$L1VmAdminPassword is empty; cannot run in-guest setup (PowerShell Direct needs credentials)."
}
