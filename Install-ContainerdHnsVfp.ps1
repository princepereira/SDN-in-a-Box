# ============================================================
#  Install-ContainerdHnsVfp.ps1 : containerd + HNS + VFP on an L1 Windows host
#  Run in an ELEVATED PowerShell session INSIDE the L1 guest
#  (after Create-L1Vm-Windows.ps1 has installed Hyper-V / Containers and
#   enabled the VFP switch extension).
#
#  Usage:
#    .\Install-ContainerdHnsVfp.ps1
#    .\Install-ContainerdHnsVfp.ps1 -NetworkMode overlay
#    .\Install-ContainerdHnsVfp.ps1 -NetworkMode l2bridge -AdapterName Ethernet -RunValidation
#    .\Install-ContainerdHnsVfp.ps1 -NetworkMode l2bridge -RunValidation -ContainerIsolation process
#
#  What it does (in order):
#    1. Verify prerequisites (elevated, Containers feature, HNS service, a
#       VFP-enabled vSwitch).
#    2. Download + install containerd ($ContainerdVersion) as a Windows service.
#    3. Download + install the Microsoft Windows CNI plugins (sdnbridge /
#       sdnoverlay / nat) into the containerd CNI bin dir.
#    4. Download the microsoft/SDN hns.psm1 helper module.
#    5. Create an HNS network ($NetworkMode: l2bridge | overlay | nat) on a
#       VFP-enabled vSwitch, then ENABLE + VERIFY the VFP switch extension on
#       the switch HNS created (so the datapath is programmed by VFP).
#    6. Write the CNI conflist that targets that HNS network.
#    7. Generate containerd's config.toml (CNI bin/conf dirs + Windows pause
#       image) and (re)start the containerd service.
#    8. Pull the base + pause images from MCR with ctr.
#    9. Install crictl (always) and, with -RunValidation, run a pod-sandbox
#       validation that drives CNI -> HNS endpoint -> VFP.
#
#  NOTE: Tunables are constants near the top of the script. Override the common
#        ones (-NetworkMode, -AdapterName, -RunValidation, versions) as params.
# ============================================================

[CmdletBinding()]
param(
    # HNS network type to create for containers.
    #   l2bridge : bridged to the host adapter (sdnbridge CNI)      [default]
    #   overlay  : VXLAN overlay (sdnoverlay CNI, needs a VSID)
    #   nat      : simple outbound-NAT network (nat CNI)
    [Parameter(Mandatory = $false)]
    [ValidateSet('l2bridge', 'overlay', 'nat')]
    [string]$NetworkMode = 'l2bridge',

    # Host network adapter the l2bridge network binds to. Empty = auto-detect
    # the fastest "Up" physical adapter (ignored for overlay/nat).
    [Parameter(Mandatory = $false)]
    [string]$AdapterName,

    # containerd release to install (Windows amd64).
    [Parameter(Mandatory = $false)]
    [string]$ContainerdVersion = '1.7.27',

    # microsoft/windows-container-networking CNI release.
    [Parameter(Mandatory = $false)]
    [string]$CniVersion = '0.3.3',

    # Install crictl and run a CNI/HNS/VFP pod-sandbox validation at the end.
    # crictl is always installed; this switch only controls the validation run.
    [Parameter(Mandatory = $false)]
    [switch]$RunValidation,

    # Container isolation used by the -RunValidation pod sandbox.
    #   hyperv  : Hyper-V isolated (runhcs-wcow-hypervisor) - cross-build safe [default]
    #   process : process-isolated (runhcs-wcow-process) - guest build must match image
    [Parameter(Mandatory = $false)]
    [ValidateSet('hyperv', 'process')]
    [string]$ContainerIsolation = 'hyperv'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------
#  Static config (edit these instead of passing arguments)
# ------------------------------------------------------------

# ---- Install locations (match containerd's Windows defaults) ----
$ContainerdRoot = 'C:\Program Files\containerd'
$CniBinDir      = Join-Path $ContainerdRoot 'cni\bin'
$CniConfDir     = Join-Path $ContainerdRoot 'cni\conf'
$ToolsBinDir    = 'C:\Tools\bin'                  # crictl + ctr shortcuts on PATH
$DownloadDir    = Join-Path $env:TEMP 'containerd-setup'

# ---- Download URLs (verified naming) ----
$ContainerdUrl = "https://github.com/containerd/containerd/releases/download/v$ContainerdVersion/containerd-$ContainerdVersion-windows-amd64.tar.gz"
$CniUrl        = "https://github.com/microsoft/windows-container-networking/releases/download/v$CniVersion/windows-container-networking-cni-amd64-v$CniVersion.zip"
$HnsModuleUrl  = 'https://raw.githubusercontent.com/microsoft/SDN/master/Kubernetes/windows/hns.psm1'
$CrictlVersion = '1.31.1'
$CrictlUrl     = "https://github.com/kubernetes-sigs/cri-tools/releases/download/v$CrictlVersion/crictl-v$CrictlVersion-windows-amd64.tar.gz"

# ---- HNS network ----
# NOTE: $CniNetworkName is used for BOTH the HNS network and the CNI "name"
#       field so the sdnbridge/sdnoverlay plugin reuses the network we create.
$CniNetworkName   = 'cbr0'
$NetworkSubnet    = '10.244.0.0/24'
$NetworkGateway   = '10.244.0.1'
$OverlayVSID      = 4096                 # VXLAN VSID (overlay mode only; >= 4096)
$DnsServers       = @('8.8.8.8', '8.8.4.4')

# ---- VFP switch extension (enabled on the vSwitch HNS creates) ----
$VfpExtensionName = 'Microsoft Azure VFP Switch Extension'

# ---- Images (pulled from MCR) ----
# IMPORTANT (build match): process isolation requires the container base image
# build to match the host OS build. On insider/iof_nf hosts there is no matching
# MCR nanoserver tag, so the validation container runs with Hyper-V isolation
# (cross-build safe). Override $BaseImage with a tag matching your host for
# process isolation, or import the local CBaseOs tar shipped in RitpBins
# (hcsintegration\image) instead.
$BaseImage    = 'mcr.microsoft.com/windows/nanoserver:ltsc2022'
$PauseImage   = 'mcr.microsoft.com/oss/kubernetes/pause:3.9'

# ------------------------------------------------------------
#  Helpers
# ------------------------------------------------------------

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

# Download a file with TLS 1.2 and a few retries.
function Get-RemoteFile {
    param(
        [Parameter(Mandatory)] [string]$Url,
        [Parameter(Mandatory)] [string]$Destination,
        [int]$Retries = 3
    )
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $dir = Split-Path -Parent $Destination
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    for ($i = 1; $i -le $Retries; $i++) {
        try {
            Write-Host "  Downloading $Url"
            Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $Destination
            Write-Host "  Saved -> $Destination"
            return
        }
        catch {
            Write-Host "  Download attempt $i/$Retries failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if ($i -eq $Retries) { throw }
            Start-Sleep -Seconds (5 * $i)
        }
    }
}

# Add a directory to the machine PATH (idempotent).
function Add-MachinePath {
    param([Parameter(Mandatory)] [string]$Dir)
    $cur = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if (($cur -split ';') -notcontains $Dir) {
        [Environment]::SetEnvironmentVariable('Path', "$cur;$Dir", 'Machine')
        Write-Host "  Added to machine PATH: $Dir"
    }
    if (($env:Path -split ';') -notcontains $Dir) { $env:Path += ";$Dir" }
}

# Resolve a usable host adapter name for l2bridge mode.
function Resolve-HostAdapter {
    param([string]$Preferred)
    if ($Preferred) {
        if (Get-NetAdapter -Name $Preferred -ErrorAction SilentlyContinue) { return $Preferred }
        throw "Adapter '$Preferred' not found. Available: $((Get-NetAdapter | Select-Object -Expand Name) -join ', ')"
    }
    $nic = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object Status -eq 'Up' |
        Sort-Object LinkSpeed -Descending |
        Select-Object -First 1
    if (-not $nic) { throw "No 'Up' physical network adapter found for l2bridge mode." }
    Write-Host "  Auto-selected host adapter: $($nic.Name)"
    return $nic.Name
}

# l2bridge only: HNS binds a physical adapter to create its bridge. If that NIC
# is already claimed by an existing external vSwitch / HNS network (e.g. a
# leftover Transparent or L2Bridge network from a prior run or Create-L1Vm),
# New-HnsNetwork fails with "An adapter was not found". Free the adapter by
# removing the HNS network(s) bound to it (and any lingering external vSwitch).
function Remove-AdapterBoundHnsNetwork {
    param([Parameter(Mandatory)] [string]$AdapterName)

    $nic = Get-NetAdapter -Name $AdapterName -ErrorAction SilentlyContinue
    if (-not $nic) { return }
    $nicDesc = $nic.InterfaceDescription

    # External vSwitches that have already claimed this physical adapter.
    $boundSwitches = @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue |
        Where-Object { $_.NetAdapterInterfaceDescription -eq $nicDesc } |
        Select-Object -Expand Name)

    $removed = $false
    foreach ($net in (Get-HnsNetwork -ErrorAction SilentlyContinue)) {
        # Never remove the network we're about to (re)create; it is handled above.
        if ($net.Name -eq $CniNetworkName) { continue }

        $adapterProp = $net.PSObject.Properties['NetworkAdapterName']
        $boundByAdapter = $adapterProp -and $adapterProp.Value -and
            ($adapterProp.Value -eq $AdapterName -or $adapterProp.Value -eq $nicDesc)
        $boundBySwitch  = $boundSwitches -contains $net.Name

        if ($boundByAdapter -or $boundBySwitch) {
            Write-Host "  Removing existing HNS network '$($net.Name)' (type $($net.Type)) bound to adapter '$AdapterName'." -ForegroundColor Yellow
            Remove-HnsNetwork $net
            $removed = $true
        }
    }

    if ($removed) { Start-Sleep 3 }

    # Remove any external vSwitch still holding the adapter so HNS can create its
    # own bridge on the freed NIC.
    foreach ($swName in @(Get-VMSwitch -SwitchType External -ErrorAction SilentlyContinue |
            Where-Object { $_.NetAdapterInterfaceDescription -eq $nicDesc } |
            Select-Object -Expand Name)) {
        Write-Host "  Removing leftover external vSwitch '$swName' still bound to '$AdapterName'." -ForegroundColor Yellow
        Remove-VMSwitch -Name $swName -Force -ErrorAction SilentlyContinue
        $removed = $true
    }

    if ($removed) { Start-Sleep 2 }
}

# ------------------------------------------------------------
#  Step 1 - prerequisites
# ------------------------------------------------------------
function Test-Prerequisites {
    Write-Section "Verifying prerequisites"
    if (-not (Test-IsAdmin)) { throw "This script must run in an ELEVATED PowerShell session." }

    $containers = Get-WindowsFeature -Name Containers -ErrorAction SilentlyContinue
    if ($containers -and -not $containers.Installed) {
        throw "The 'Containers' feature is not installed. Run Create-L1Vm-Windows.ps1 (or Install-WindowsFeature Containers) first."
    }
    Write-Host "  Containers feature: installed"

    $hns = Get-Service -Name hns -ErrorAction SilentlyContinue
    if (-not $hns) {
        throw "Host Network Service (hns) not found. Ensure the Containers feature is installed and the guest was rebooted."
    }
    if ($hns.Status -ne 'Running') { Start-Service hns; Start-Sleep 3 }
    Write-Host "  HNS service: $((Get-Service hns).Status)"

    # At least one VFP-enabled vSwitch must exist (proves VFP driver is live).
    $vfpSwitch = Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object {
        Get-VMSwitchExtension -VMSwitchName $_.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $VfpExtensionName -and $_.Enabled }
    }
    if ($vfpSwitch) {
        Write-Host "  VFP extension enabled on vSwitch(es): $(( $vfpSwitch | Select-Object -Expand Name) -join ', ')"
    }
    else {
        Write-Host "  WARNING: no vSwitch currently has '$VfpExtensionName' enabled." -ForegroundColor Yellow
        Write-Host "           It will be enabled on the switch HNS creates below. If the" -ForegroundColor Yellow
        Write-Host "           VFP driver (vfpext) has never started, reboot the L1 guest first." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
#  Step 2 - containerd
# ------------------------------------------------------------
function Install-Containerd {
    Write-Section "Installing containerd $ContainerdVersion"
    $bin           = Join-Path $ContainerdRoot 'bin'
    $containerdExe = Join-Path $bin 'containerd.exe'

    # Skip download/extract if the target version is already installed.
    if (Test-Path $containerdExe) {
        $ver = (& $containerdExe --version) 2>$null
        if ($ver -match [regex]::Escape("v$ContainerdVersion")) {
            Write-Host "  containerd $ContainerdVersion already installed; skipping download/extract."
            Add-MachinePath -Dir $bin
            New-Item -ItemType Directory -Force -Path $CniBinDir, $CniConfDir | Out-Null
            Write-Host "  $ver"
            return
        }
        Write-Host "  Installed containerd differs from target $ContainerdVersion; reinstalling."
    }

    $tar = Join-Path $DownloadDir "containerd-$ContainerdVersion.tar.gz"
    Get-RemoteFile -Url $ContainerdUrl -Destination $tar

    # Stop an existing service before overwriting binaries.
    if (Get-Service containerd -ErrorAction SilentlyContinue) {
        Write-Host "  Existing containerd service found; stopping it."
        Stop-Service containerd -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $ContainerdRoot)) { New-Item -ItemType Directory -Force -Path $ContainerdRoot | Out-Null }
    # The archive lays out bin\containerd.exe, bin\ctr.exe, ... Extract its bin
    # into $ContainerdRoot\bin via the in-box tar (handles .tar.gz).
    Write-Host "  Extracting to $ContainerdRoot"
    tar.exe -xf $tar -C $ContainerdRoot
    if ($LASTEXITCODE -ne 0) { throw "tar extraction of containerd failed (exit $LASTEXITCODE)." }

    Add-MachinePath -Dir $bin

    New-Item -ItemType Directory -Force -Path $CniBinDir, $CniConfDir | Out-Null

    if (-not (Test-Path $containerdExe)) { throw "containerd.exe not found at $containerdExe after extraction." }
    & $containerdExe --version
}

function Write-ContainerdConfig {
    Write-Section "Generating containerd config.toml"
    $bin           = Join-Path $ContainerdRoot 'bin'
    $containerdExe = Join-Path $bin 'containerd.exe'
    $cfgPath       = Join-Path $ContainerdRoot 'config.toml'

    $cfg = & $containerdExe config default
    # Point the CRI CNI integration at our bin/conf dirs and set the Windows
    # pause image. Paths use doubled backslashes for valid TOML.
    $binToml  = $CniBinDir.Replace('\', '\\')
    $confToml = $CniConfDir.Replace('\', '\\')
    $cfg = $cfg `
        -replace '(?m)^(\s*bin_dir\s*=\s*).*$',  "`${1}`"$binToml`"" `
        -replace '(?m)^(\s*conf_dir\s*=\s*).*$', "`${1}`"$confToml`"" `
        -replace '(?m)^(\s*sandbox_image\s*=\s*).*$', "`${1}`"$PauseImage`""
    Set-Content -Path $cfgPath -Value $cfg -Encoding ascii
    Write-Host "  Wrote $cfgPath (cni bin_dir=$CniBinDir, conf_dir=$CniConfDir, sandbox_image=$PauseImage)"
}

function Register-Containerd {
    Write-Section "Registering + starting the containerd service"
    $containerdExe = Join-Path $ContainerdRoot 'bin\containerd.exe'
    if (-not (Get-Service containerd -ErrorAction SilentlyContinue)) {
        & $containerdExe --register-service
        if ($LASTEXITCODE -ne 0) { throw "containerd --register-service failed (exit $LASTEXITCODE)." }
    }
    Set-Service containerd -StartupType Automatic
    Start-Service containerd
    Start-Sleep 3
    Write-Host "  containerd service: $((Get-Service containerd).Status)"
}

# ------------------------------------------------------------
#  Step 3 - CNI plugins
# ------------------------------------------------------------
function Install-CniPlugins {
    Write-Section "Installing Windows CNI plugins $CniVersion"
    $expected = @('sdnbridge.exe', 'sdnoverlay.exe', 'nat.exe')
    $present  = @(Get-ChildItem -Path $CniBinDir -Filter *.exe -ErrorAction SilentlyContinue |
        Select-Object -Expand Name)
    if ($present.Count -and -not ($expected | Where-Object { $present -notcontains $_ })) {
        Write-Host "  CNI plugins already present in $CniBinDir : $($present -join ', '); skipping download."
        return
    }

    $zip = Join-Path $DownloadDir "windows-cni-$CniVersion.zip"
    Get-RemoteFile -Url $CniUrl -Destination $zip
    Expand-Archive -Path $zip -DestinationPath $CniBinDir -Force
    $plugins = Get-ChildItem -Path $CniBinDir -Filter *.exe -ErrorAction SilentlyContinue |
        Select-Object -Expand Name
    Write-Host "  CNI plugins in $CniBinDir : $($plugins -join ', ')"
    if (-not $plugins) { throw "No CNI plugin executables found after extraction." }
}

# ------------------------------------------------------------
#  Step 4/5 - HNS network (VFP-backed)
# ------------------------------------------------------------
function Import-HnsModule {
    Write-Section "Loading HNS helper module"
    $module = Join-Path $DownloadDir 'hns.psm1'
    if (Test-Path $module) {
        Write-Host "  Reusing already-downloaded hns.psm1"
    }
    else {
        Get-RemoteFile -Url $HnsModuleUrl -Destination $module
    }
    Import-Module $module -Force -DisableNameChecking
    Write-Host "  Imported hns.psm1"
}

function New-ContainerNetwork {
    Write-Section "Creating HNS network '$CniNetworkName' ($NetworkMode)"

    # The HNS network name ($CniNetworkName) is shared across all modes, so a
    # name-only reuse check would keep a stale network of the WRONG type when
    # the user switches -NetworkMode (e.g. l2bridge -> overlay). That leaves the
    # sdnoverlay conflist (SDNRoute/NeedEncap) layered on an L2Bridge datapath,
    # which black-holes all pod-to-pod + gateway traffic. Only reuse when the
    # existing network's type matches the requested mode; otherwise rebuild it.
    $expectedType = switch ($NetworkMode) {
        'l2bridge' { 'L2Bridge' }
        'overlay'  { 'Overlay' }
        'nat'      { 'NAT' }
    }
    $existing = Get-HnsNetwork -ErrorAction SilentlyContinue | Where-Object Name -eq $CniNetworkName
    if ($existing) {
        if ("$($existing.Type)" -ieq $expectedType) {
            Write-Host "  HNS network '$CniNetworkName' (type $($existing.Type)) already exists; reusing it."
            return
        }
        Write-Host "  HNS network '$CniNetworkName' exists but is type '$($existing.Type)', not '$expectedType' for mode '$NetworkMode'. Rebuilding it." -ForegroundColor Yellow
        Write-Host "  NOTE: any pods created against the old network must be recreated (e.g. Remove-VfpPod + New-VfpPod) to pick up the new datapath." -ForegroundColor Yellow
        Remove-HnsNetwork $existing
        Start-Sleep 3
    }

    switch ($NetworkMode) {
        'l2bridge' {
            $adapter = Resolve-HostAdapter -Preferred $AdapterName
            Remove-AdapterBoundHnsNetwork -AdapterName $adapter
            New-HnsNetwork -Type L2Bridge -Name $CniNetworkName `
                -AddressPrefix $NetworkSubnet -Gateway $NetworkGateway `
                -AdapterName $adapter -DNSServer ($DnsServers -join ',') | Out-Null
        }
        'overlay' {
            $subnetPolicy = @{ Type = 'VSID'; VSID = $OverlayVSID }
            New-HnsNetwork -Type Overlay -Name $CniNetworkName `
                -AddressPrefix $NetworkSubnet -Gateway $NetworkGateway `
                -SubnetPolicies @($subnetPolicy) -DNSServer ($DnsServers -join ',') | Out-Null
        }
        'nat' {
            New-HnsNetwork -Type NAT -Name $CniNetworkName `
                -AddressPrefix $NetworkSubnet -Gateway $NetworkGateway `
                -DNSServer ($DnsServers -join ',') | Out-Null
        }
    }
    Start-Sleep 3
    if (-not (Get-HnsNetwork | Where-Object Name -eq $CniNetworkName)) {
        throw "HNS network '$CniNetworkName' was not created."
    }
    Write-Host "  Created HNS network '$CniNetworkName'."
}

# Enable + verify the VFP switch extension on the vSwitch HNS just created, so
# the container datapath is programmed by VFP.
function Enable-VfpOnNetworkSwitch {
    Write-Section "Ensuring VFP is enabled on the container vSwitch"
    # HNS creates a vSwitch whose name contains the network name.
    $sw = Get-VMSwitch -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$CniNetworkName*" } |
        Select-Object -First 1
    if (-not $sw) {
        # Fall back: NAT/overlay HNS switches may be named after the network type.
        $sw = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if (-not $sw) { Write-Host "  WARNING: could not locate the HNS vSwitch to enable VFP on." -ForegroundColor Yellow; return }

    $ext = Get-VMSwitchExtension -VMSwitchName $sw.Name -ErrorAction SilentlyContinue |
        Where-Object Name -eq $VfpExtensionName
    if ($ext -and -not $ext.Enabled) {
        for ($i = 1; $i -le 5 -and -not (Get-VMSwitchExtension -VMSwitchName $sw.Name | Where-Object { $_.Name -eq $VfpExtensionName -and $_.Enabled }); $i++) {
            try { Enable-VMSwitchExtension -VMSwitchName $sw.Name -Name $VfpExtensionName -ErrorAction Stop | Out-Null } catch {}
            Start-Sleep 2
        }
    }
    $nowEnabled = Get-VMSwitchExtension -VMSwitchName $sw.Name -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq $VfpExtensionName -and $_.Enabled }
    if ($nowEnabled) {
        Write-Host "  VFP extension enabled on vSwitch '$($sw.Name)'."
    }
    else {
        Write-Host "  WARNING: VFP extension NOT enabled on '$($sw.Name)'. Run:" -ForegroundColor Yellow
        Write-Host "           Enable-VMSwitchExtension -VMSwitchName '$($sw.Name)' -Name '$VfpExtensionName'" -ForegroundColor Yellow
    }

    # Surface VFP's view of the switch ports (Error (2) => vfpext not started: reboot).
    Write-Host "  vfpctrl /list-vmswitch-port :"
    cmd /c "vfpctrl /list-vmswitch-port" 2>&1 | ForEach-Object { Write-Host "    $_" }
}

# ------------------------------------------------------------
#  L2Bridge same-host local delivery (network-level, no control plane)
#
#  On this nested SDN host every l2bridge pod port carries a VFP
#  VNET_PA_ROUTE layer whose catch-all PA_ROUTE rule (Type: paroute) delegates
#  next-hop IP->MAC resolution to the HOST network compartment on the interface
#  that owns the network ManagementIP (the host management vNIC). HNS programs
#  that rule, but with no control plane / NC host-agent present nothing
#  populates the host side, so same-subnet pod traffic falls to the catch-all
#  and is resolved off-box -> black-holed. Making the pod subnet on-link on that
#  interface lets paroute resolve peers locally over the shared vSwitch. This
#  adds ZERO VFP rules - only a host route + forwarding, the exact input the
#  HNS paroute rule consumes. Set once per network here; per-pod static
#  neighbors (New-VfpPod.ps1) only remove the first-packet ARP warm-up.
# ------------------------------------------------------------
function Set-L2BridgePaRouteDelivery {
    if ($NetworkMode -ne 'l2bridge') { return }   # l2bridge only; nat/overlay unaffected
    Write-Section "L2Bridge PA-route local delivery (host on-link route)"

    $net = Get-HnsNetwork -ErrorAction SilentlyContinue | Where-Object Name -eq $CniNetworkName | Select-Object -First 1
    if (-not $net) { Write-Host "  Network '$CniNetworkName' not found; skipping." -ForegroundColor Yellow; return }

    $mgmtIp = "$($net.ManagementIP)".Trim()
    if (-not $mgmtIp) { Write-Host "  Network has no ManagementIP yet; skipping." -ForegroundColor Yellow; return }
    $mgmtAddr = Get-NetIPAddress -IPAddress $mgmtIp -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mgmtAddr) { Write-Host "  No interface owns ManagementIP $mgmtIp; skipping." -ForegroundColor Yellow; return }

    $ifIndex = $mgmtAddr.InterfaceIndex
    Write-Host "  PA-route interface : ifIndex $ifIndex ($($mgmtAddr.InterfaceAlias)) owns ManagementIP $mgmtIp"
    Write-Host "  Pod subnet         : $NetworkSubnet"

    # (a) forward between the mgmt vNIC and the pod ports
    Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Forwarding Enabled -ErrorAction SilentlyContinue
    # (b) on-link route for the pod subnet via the PA-route interface (idempotent)
    if (-not (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix $NetworkSubnet -ErrorAction SilentlyContinue)) {
        New-NetRoute -DestinationPrefix $NetworkSubnet -InterfaceIndex $ifIndex -NextHop '0.0.0.0' -ErrorAction SilentlyContinue | Out-Null
    }
    Write-Host "  Forwarding enabled + on-link route for $NetworkSubnet via ifIndex $ifIndex." -ForegroundColor Green
}

# ------------------------------------------------------------
#  Step 6 - CNI conflist
# ------------------------------------------------------------
function Write-CniConf {
    Write-Section "Writing CNI conflist for '$CniNetworkName'"
    $pluginType = switch ($NetworkMode) {
        'l2bridge' { 'sdnbridge' }
        'overlay'  { 'sdnoverlay' }
        'nat'      { 'nat' }
    }

    # Endpoint policies in HCN (v2) schema — sdnbridge/sdnoverlay call
    # hcnCreateEndpoint, which rejects the legacy HNS v1 names/shape
    # (e.g. Type "ROUTE" or a bare "ExceptionList") with UnknownEnumValue.
    #
    # OutBoundNAT: SNAT pod traffic to the host IP for off-subnet/internet
    # access, excepting the pod subnet itself (intra-subnet stays un-NAT'd).
    $outboundNat = [ordered]@{
        Name  = 'EndpointPolicy'
        Value = [ordered]@{ Type = 'OutBoundNAT'; Settings = [ordered]@{ Exceptions = @($NetworkSubnet) } }
    }

    # SDNRoute with NeedEncap=$true is an OVERLAY (VXLAN) construct: it tells
    # VFP to encapsulate traffic to the destination prefix. It must NOT be
    # applied to an l2bridge pod subnet — doing so installs a VXLAN routeencap
    # rule over 10.244.0.0/24 (including the gateway), black-holing all
    # intra-subnet and gateway traffic. Only overlay networks get it.
    $policies = @($outboundNat)
    if ($NetworkMode -eq 'overlay') {
        $encapRoute = [ordered]@{
            Name  = 'EndpointPolicy'
            Value = [ordered]@{ Type = 'SDNRoute'; Settings = [ordered]@{ DestinationPrefix = $NetworkSubnet; NeedEncap = $true } }
        }
        $policies += $encapRoute
    }

    $conf = [ordered]@{
        cniVersion = '0.3.0'
        name       = $CniNetworkName
        type       = $pluginType
        master     = if ($NetworkMode -eq 'l2bridge') { (Resolve-HostAdapter -Preferred $AdapterName) } else { 'Ethernet' }
        capabilities = [ordered]@{ portMappings = $true; dns = $true }
        ipam       = [ordered]@{
            environment = 'azure'
            subnet      = $NetworkSubnet
            routes      = @(@{ GW = $NetworkGateway })
        }
        dns        = [ordered]@{ Nameservers = $DnsServers }
        AdditionalArgs = $policies
    }
    if ($NetworkMode -eq 'nat') { $conf.Remove('master') }

    $conflist = [ordered]@{
        cniVersion = '0.3.0'
        name       = $CniNetworkName
        plugins    = @($conf)
    }

    $path = Join-Path $CniConfDir "0-$CniNetworkName.conflist"
    $conflist | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding ascii
    Write-Host "  Wrote $path"
}

# ------------------------------------------------------------
#  Step 8 - images
# ------------------------------------------------------------
function Get-ContainerImages {
    Write-Section "Pulling images from MCR"
    $ctr = Join-Path $ContainerdRoot 'bin\ctr.exe'
    foreach ($img in @($PauseImage, $BaseImage)) {
        Write-Host "  ctr pull $img"
        & $ctr -n k8s.io images pull $img
        if ($LASTEXITCODE -ne 0) {
            Write-Host "  WARNING: pull failed for $img (check guest internet / tag). Continuing." -ForegroundColor Yellow
        }
    }
}

# ------------------------------------------------------------
#  Step 9 - optional crictl validation
# ------------------------------------------------------------
function Install-Crictl {
    Write-Section "Installing crictl $CrictlVersion"
    $crictlExe = Join-Path $ToolsBinDir 'crictl.exe'
    $alreadyInstalled = $false
    if (Test-Path $crictlExe) {
        $ver = (& $crictlExe --version) 2>$null
        if ($ver -match [regex]::Escape($CrictlVersion)) {
            Write-Host "  crictl $CrictlVersion already installed; skipping download/extract."
            $alreadyInstalled = $true
        }
        else {
            Write-Host "  Installed crictl differs from target $CrictlVersion; reinstalling."
        }
    }

    if (-not $alreadyInstalled) {
        $tar = Join-Path $DownloadDir "crictl-$CrictlVersion.tar.gz"
        Get-RemoteFile -Url $CrictlUrl -Destination $tar
        New-Item -ItemType Directory -Force -Path $ToolsBinDir | Out-Null
        tar.exe -xf $tar -C $ToolsBinDir
        if ($LASTEXITCODE -ne 0) { throw "tar extraction of crictl failed (exit $LASTEXITCODE)." }
    }
    Add-MachinePath -Dir $ToolsBinDir

    $crictlYaml = 'C:\Program Files\containerd\crictl.yaml'
    @(
        'runtime-endpoint: npipe://./pipe/containerd-containerd'
        'image-endpoint: npipe://./pipe/containerd-containerd'
        'timeout: 30'
    ) | Set-Content -Path $crictlYaml -Encoding ascii
    [Environment]::SetEnvironmentVariable('CONTAINERD_ADDRESS', '\\.\pipe\containerd-containerd', 'Machine')
    $env:CRI_CONFIG_FILE = $crictlYaml
    [Environment]::SetEnvironmentVariable('CRI_CONFIG_FILE', $crictlYaml, 'Machine')
    Write-Host "  crictl configured against containerd ($crictlYaml)."
}

function Invoke-Validation {
    Write-Section "Validating containerd + CNI + HNS + VFP"
    $crictl = Join-Path $ToolsBinDir 'crictl.exe'
    if (-not (Test-Path $crictl)) { Write-Host "  crictl not installed; skipping pod validation." -ForegroundColor Yellow; return }

    $work = Join-Path $DownloadDir 'validation'
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    $isHyperV  = ($ContainerIsolation -ne 'process')
    $runtime   = if ($isHyperV) { 'runhcs-wcow-hypervisor' } else { 'runhcs-wcow-process' }
    Write-Host "  Isolation: $(if ($isHyperV) {'Hyper-V'} else {'process'})  (runtime handler: $runtime)"
    $podJson = @{
        metadata    = @{ name = 'vfp-test-sandbox'; namespace = 'default'; attempt = 1 }
        log_directory = $work
        linux       = @{}
        windows     = @{ security_context = @{ host_process = $false } }
        annotations = @{ 'io.microsoft.virtualMachine.isolated' = "$($isHyperV.ToString().ToLower())" }
    } | ConvertTo-Json -Depth 6
    $podPath = Join-Path $work 'pod.json'
    Set-Content -Path $podPath -Value $podJson -Encoding ascii

    Write-Host "  Creating a pod sandbox (drives CNI -> HNS endpoint -> VFP)..."
    $podId = & $crictl runp --runtime $runtime $podPath 2>&1
    Write-Host "  crictl runp -> $podId"
    if ($LASTEXITCODE -eq 0 -and $podId) {
        Write-Host "  Pod sandbox created. HNS endpoints:"
        Get-HnsEndpoint -ErrorAction SilentlyContinue | Select-Object Name, IPAddress, MacAddress |
            Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }
        Write-Host "  Cleaning up the validation sandbox..."
        & $crictl stopp $podId  | Out-Null
        & $crictl rmp  $podId   | Out-Null
    }
    else {
        Write-Host "  WARNING: pod sandbox creation failed. Inspect with: crictl runp --runtime $runtime $podPath" -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------
#  Main
# ------------------------------------------------------------
Write-Host "Install-ContainerdHnsVfp : containerd=$ContainerdVersion cni=$CniVersion mode=$NetworkMode" -ForegroundColor Green
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null

Test-Prerequisites
Install-Containerd
Install-CniPlugins
Import-HnsModule
New-ContainerNetwork
Enable-VfpOnNetworkSwitch
Set-L2BridgePaRouteDelivery
Write-CniConf
Write-ContainerdConfig
Register-Containerd
Get-ContainerImages
Install-Crictl

if ($RunValidation) {
    Invoke-Validation
}

Write-Section "Done"
Write-Host "containerd service : $((Get-Service containerd -ErrorAction SilentlyContinue).Status)"
Write-Host "HNS network        : $CniNetworkName ($NetworkMode)"
Write-Host "CNI conf           : $(Join-Path $CniConfDir "0-$CniNetworkName.conflist")"
Write-Host ""
Write-Host "Verify:" -ForegroundColor Cyan
Write-Host "  & '$ContainerdRoot\bin\ctr.exe' version"
Write-Host "  & '$ContainerdRoot\bin\ctr.exe' -n k8s.io images ls"
Write-Host "  Get-HnsNetwork | Select Name,Type,Subnets"
Write-Host "  Get-VMSwitchExtension -VMSwitchName <switch> | Select Name,Enabled   # VFP must be Enabled"
Write-Host "  vfpctrl /list-vmswitch-port                                           # Error (2) => reboot (vfpext not started)"
Write-Host "  & '$ToolsBinDir\crictl.exe' pods"
Write-Host "  & '$ToolsBinDir\crictl.exe' images"
