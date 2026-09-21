# ============================================================
#  New-VfpPod.ps1 : create a pod sandbox wired to a VFP port (rules by HNS)
#  Run in an ELEVATED PowerShell session INSIDE the L1 Windows guest, AFTER
#  Install-ContainerdHnsVfp.ps1 has set up containerd + an HNS network on a
#  VFP-enabled vSwitch.
#
#  What it does:
#    1. Verify prerequisites (elevated, containerd running, crictl present,
#       the target HNS network exists, VFP enabled on that network's vSwitch).
#    2. Create a pod sandbox with crictl, then run a workload container in it
#       (so the pod is exec-able). This drives:
#         crictl runp -> CRI -> CNI (sdnbridge/sdnoverlay/nat) -> HNS endpoint
#         -> the endpoint attaches to a port on the VFP-enabled vSwitch and
#            HNS programs the VFP rules/policies on that port.
#    3. Correlate the new HNS endpoint -> VFP switch port (by MAC) and dump the
#       VFP port state + the rules HNS programmed (vfpctrl).
#    4. Leave the pod running (default) or tear it down (-Cleanup).
#
#  Usage:
#    .\New-VfpPod.ps1 sender                       # positional pod name + container
#    .\New-VfpPod.ps1 -Name listener
#    .\New-VfpPod.ps1 sender -Image mcr.microsoft.com/windows/servercore:ltsc2022
#    .\New-VfpPod.ps1 sender -SandboxOnly           # pod sandbox only (not exec-able)
#    .\New-VfpPod.ps1 sender -ProcessIsolation      # process-isolated (build must match)
#    .\New-VfpPod.ps1 sender -Cleanup               # create, verify, then remove
#
#  Exec in once it is running:
#    crictl exec -it <container-id> cmd
# ============================================================

[CmdletBinding()]
param(
    # Name for the pod sandbox (e.g. "sender", "listener"). Positional, so
    #   .\New-VfpPod.ps1 sender
    # and  .\New-VfpPod.ps1 -Name listener  both work.
    [Parameter(Mandatory = $false, Position = 0)]
    [Alias('Name')]
    [string]$PodName = 'vfp-pod',

    # Kubernetes namespace recorded in the sandbox metadata.
    [Parameter(Mandatory = $false)]
    [string]$Namespace = 'default',

    # HNS network (and CNI "name") the pod attaches to. Must already exist
    # (created by Install-ContainerdHnsVfp.ps1).
    [Parameter(Mandatory = $false)]
    [string]$NetworkName = 'cbr0',

    # Use process isolation instead of Hyper-V isolation. Process isolation
    # requires the container base image build to match the host OS build.
    [Parameter(Mandatory = $false)]
    [switch]$ProcessIsolation,

    # Container image to run inside the pod (so you can `crictl exec` into it).
    [Parameter(Mandatory = $false)]
    [string]$Image = 'mcr.microsoft.com/windows/nanoserver:ltsc2022',

    # Long-running command that keeps the container alive. Default pings the
    # loopback forever (works on nanoserver, which has no PowerShell).
    [Parameter(Mandatory = $false)]
    [string[]]$Command = @('cmd', '/c', 'ping -t 127.0.0.1'),

    # Create only the pod sandbox (no workload container; not exec-able).
    [Parameter(Mandatory = $false)]
    [switch]$SandboxOnly,

    # Remove the pod sandbox after verifying the VFP wiring.
    [Parameter(Mandatory = $false)]
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# ------------------------------------------------------------
#  Static config (match Install-ContainerdHnsVfp.ps1 defaults)
# ------------------------------------------------------------
$ContainerdRoot = 'C:\Program Files\containerd'
$ToolsBinDir    = 'C:\Tools\bin'
$DownloadDir    = Join-Path $env:TEMP 'containerd-setup'
$CrictlExe      = Join-Path $ToolsBinDir 'crictl.exe'
$CtrExe         = Join-Path $ContainerdRoot 'bin\ctr.exe'
$VfpExtension   = 'Microsoft Azure VFP Switch Extension'

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

# Normalize a MAC ("00-15-5D-01-CC-10", "00155D01CC10", "00:15:...") to hex digits.
function ConvertTo-MacKey {
    param([string]$Mac)
    if (-not $Mac) { return '' }
    return ($Mac -replace '[^0-9A-Fa-f]', '').ToUpper()
}

# Make the HNS helper cmdlets (Get-HnsNetwork / Get-HnsEndpoint) available.
function Import-HnsModule {
    if (Get-Command Get-HnsEndpoint -ErrorAction SilentlyContinue) { return }
    $candidates = @(
        (Join-Path $DownloadDir 'hns.psm1'),
        'C:\k\hns.psm1',
        (Join-Path $ToolsBinDir 'hns.psm1')
    )
    foreach ($m in $candidates) {
        if (Test-Path $m) { Import-Module $m -Force -DisableNameChecking; break }
    }
    if (-not (Get-Command Get-HnsEndpoint -ErrorAction SilentlyContinue)) {
        throw "HNS helper cmdlets not found. Run Install-ContainerdHnsVfp.ps1 first (it downloads hns.psm1 to $DownloadDir)."
    }
}

# Parse `vfpctrl /list-vmswitch-port` into [pscustomobject]{ PortName; Mac; MacKey; Switch }.
function Get-VfpSwitchPort {
    $raw = cmd /c "vfpctrl /list-vmswitch-port" 2>&1
    $ports = @()
    $cur = $null
    foreach ($line in $raw) {
        $t = "$line".Trim()
        if ($t -match '^Port name\s*:\s*(.+)$') {
            if ($cur) { $ports += $cur }
            $cur = [pscustomobject]@{ PortName = $Matches[1].Trim(); Mac = ''; MacKey = ''; Switch = '' }
        }
        elseif ($cur -and $t -match '^(MAC [Aa]ddress|Mac Address)\s*:\s*(.+)$') {
            $cur.Mac    = $Matches[2].Trim()
            $cur.MacKey = ConvertTo-MacKey $cur.Mac
        }
        elseif ($cur -and $t -match '^Switch [Ff]riendly name\s*:\s*(.+)$') {
            $cur.Switch = $Matches[1].Trim()
        }
    }
    if ($cur) { $ports += $cur }
    return @($ports), $raw
}

function Invoke-VfpPort {
    param([string]$PortName, [string]$VfpCommand)
    $out = cmd /c "vfpctrl /port $PortName $VfpCommand" 2>&1
    return $out
}

# ------------------------------------------------------------
#  L2Bridge same-host local delivery - PER-POD neighbor (NO control plane)
#
#  The network-level enabler (forwarding + on-link pod-subnet route on the
#  management vNIC that owns ManagementIP) is set once by
#  Install-ContainerdHnsVfp.ps1 (Set-L2BridgePaRouteDelivery). With that route
#  in place, the HNS-programmed VFP PA_ROUTE (Type: paroute) rule resolves peer
#  pods locally via the host compartment on that interface; dynamic ARP alone
#  works but costs a 1-2 packet warm-up on first contact. This per-pod step adds
#  a single static neighbor (pod IP -> pod MAC) on that interface so the very
#  first packet resolves on-box. It adds ZERO VFP rules - only the host-stack
#  input the HNS paroute rule consumes. As a safety net it also ensures the
#  network-level route/forwarding exist (idempotent) in case a pod is created
#  without having re-run the installer.
# ------------------------------------------------------------
function Set-L2BridgeLocalDelivery {
    param($Network, $Endpoint)

    if (-not $Network -or "$($Network.Type)" -notmatch 'L2Bridge') { return }   # l2bridge only
    if (-not $Endpoint -or -not $Endpoint.IPAddress -or -not $Endpoint.MacAddress) { return }

    Write-Section "L2Bridge local-delivery neighbor (same-host pod-to-pod)"

    $mgmtIp = "$($Network.ManagementIP)".Trim()
    if (-not $mgmtIp) { Write-Host "  No ManagementIP on network; skipping." -ForegroundColor Yellow; return }
    $mgmtAddr = Get-NetIPAddress -IPAddress $mgmtIp -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $mgmtAddr) { Write-Host "  No interface owns ManagementIP $mgmtIp; skipping." -ForegroundColor Yellow; return }

    $ifIndex = $mgmtAddr.InterfaceIndex
    $subnet  = @($Network.Subnets)[0].AddressPrefix
    $podIp   = "$($Endpoint.IPAddress)".Trim()
    $podMac  = ("$($Endpoint.MacAddress)" -replace ':', '-').ToUpper()

    Write-Host "  PA-route interface : ifIndex $ifIndex ($($mgmtAddr.InterfaceAlias)) owns ManagementIP $mgmtIp"
    Write-Host "  Registering pod    : $podIp -> $podMac"

    # Safety net: the network-level forwarding + on-link route are normally set
    # once by the installer. Ensure they exist here too (idempotent, no-op when
    # already present) so a pod created without re-running the installer works.
    if (-not (Get-NetRoute -InterfaceIndex $ifIndex -DestinationPrefix $subnet -ErrorAction SilentlyContinue)) {
        Set-NetIPInterface -InterfaceIndex $ifIndex -AddressFamily IPv4 -Forwarding Enabled -ErrorAction SilentlyContinue
        New-NetRoute -DestinationPrefix $subnet -InterfaceIndex $ifIndex -NextHop '0.0.0.0' -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  (on-link route was missing; added as fallback - consider re-running the installer)" -ForegroundColor Yellow
    }

    # Per-pod static neighbor: pod IP -> pod MAC on the PA-route interface. This
    # is the only genuinely per-pod step; it removes the first-packet ARP warm-up.
    Remove-NetNeighbor -InterfaceIndex $ifIndex -IPAddress $podIp -Confirm:$false -ErrorAction SilentlyContinue
    New-NetNeighbor -InterfaceIndex $ifIndex -IPAddress $podIp -LinkLayerAddress $podMac -State Permanent -ErrorAction SilentlyContinue | Out-Null

    Write-Host "  Done. Peer pods on this host resolve on-box (static neighbor)." -ForegroundColor Green
}

# ------------------------------------------------------------
#  Step 1 - prerequisites
# ------------------------------------------------------------
function Test-Prerequisites {
    Write-Section "Verifying prerequisites"
    if (-not (Test-IsAdmin)) { throw "This script must run in an ELEVATED PowerShell session." }

    $svc = Get-Service containerd -ErrorAction SilentlyContinue
    if (-not $svc) { throw "containerd service not found. Run Install-ContainerdHnsVfp.ps1 first." }
    if ($svc.Status -ne 'Running') { Start-Service containerd; Start-Sleep 3 }
    Write-Host "  containerd service: $((Get-Service containerd).Status)"

    if (-not (Test-Path $CrictlExe)) { throw "crictl not found at $CrictlExe. Run Install-ContainerdHnsVfp.ps1 (it installs crictl)." }
    Write-Host "  crictl: $CrictlExe"

    Import-HnsModule
    $net = Get-HnsNetwork -ErrorAction SilentlyContinue | Where-Object Name -eq $NetworkName
    if (-not $net) {
        $have = (Get-HnsNetwork -ErrorAction SilentlyContinue | Select-Object -Expand Name) -join ', '
        throw "HNS network '$NetworkName' not found. Existing: $have. Create it with Install-ContainerdHnsVfp.ps1."
    }
    Write-Host "  HNS network '$NetworkName' (type $($net.Type)) present."

    # VFP must be enabled on the network's vSwitch so HNS can program rules.
    $sw = Get-VMSwitch -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*$NetworkName*" } | Select-Object -First 1
    if (-not $sw) { $sw = Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if ($sw) {
        $ext = Get-VMSwitchExtension -VMSwitchName $sw.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $VfpExtension -and $_.Enabled }
        if ($ext) { Write-Host "  VFP enabled on vSwitch '$($sw.Name)'." }
        else { Write-Host "  WARNING: VFP not confirmed enabled on vSwitch '$($sw.Name)'." -ForegroundColor Yellow }
    }
}

# ------------------------------------------------------------
#  Step 2 - create the pod sandbox (CNI -> HNS endpoint -> VFP port)
# ------------------------------------------------------------
function New-PodSandbox {
    Write-Section "Creating pod sandbox '$PodName' (CNI -> HNS endpoint -> VFP)"
    $work = Join-Path $DownloadDir "pod-$PodName"
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    $isolated = -not $ProcessIsolation.IsPresent
    $pod = [ordered]@{
        metadata      = [ordered]@{ name = $PodName; namespace = $Namespace; uid = ([guid]::NewGuid().ToString()); attempt = 1 }
        log_directory = $work
        linux         = @{}
        windows       = @{ security_context = @{ host_process = $false } }
    }
    if ($isolated) { $pod['annotations'] = @{ 'io.microsoft.virtualMachine.isolated' = 'true' } }

    $podPath = Join-Path $work 'pod.json'
    ($pod | ConvertTo-Json -Depth 6) | Set-Content -Path $podPath -Encoding ascii

    $runtime = if ($isolated) { 'runhcs-wcow-hypervisor' } else { 'runhcs-wcow-process' }
    Write-Host "  Isolation: $(if ($isolated) {'Hyper-V'} else {'process'})  (runtime handler: $runtime)"

    $podId = (& $CrictlExe runp --runtime $runtime $podPath 2>&1) | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or -not $podId -or $podId -match '\s') {
        Write-Host "  crictl runp output: $podId" -ForegroundColor Yellow
        throw "Pod sandbox creation failed. Retry manually: `"$CrictlExe`" runp --runtime $runtime `"$podPath`""
    }
    Write-Host "  Pod sandbox created. Pod ID: $podId"
    return $podId
}

# ------------------------------------------------------------
#  Step 2b - run a workload container in the sandbox (so it is exec-able)
# ------------------------------------------------------------
function New-PodContainer {
    param([Parameter(Mandatory)] [string]$PodId)
    Write-Section "Starting container in pod '$PodName' (image $Image)"
    $work = Join-Path $DownloadDir "pod-$PodName"
    $podPath = Join-Path $work 'pod.json'

    # Ensure the image is present (idempotent).
    Write-Host "  Ensuring image is pulled: $Image"
    & $CrictlExe pull $Image 2>&1 | ForEach-Object { Write-Host "    $_" }

    $ctr = [ordered]@{
        metadata = [ordered]@{ name = $PodName; attempt = 1 }
        image    = [ordered]@{ image = $Image }
        command  = @($Command)
        log_path = "$PodName.log"
        windows  = @{ security_context = @{ host_process = $false } }
    }
    $ctrPath = Join-Path $work 'container.json'
    ($ctr | ConvertTo-Json -Depth 6) | Set-Content -Path $ctrPath -Encoding ascii

    $ctrId = (& $CrictlExe create $PodId $ctrPath $podPath 2>&1) | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0 -or -not $ctrId -or $ctrId -match '\s') {
        Write-Host "  crictl create output: $ctrId" -ForegroundColor Yellow
        Write-Host "  WARNING: container creation failed (pod sandbox + VFP wiring are still up)." -ForegroundColor Yellow
        return $null
    }
    & $CrictlExe start $ctrId 2>&1 | ForEach-Object { Write-Host "    $_" }
    Write-Host "  Container started. Container ID: $ctrId"
    return $ctrId
}

# ------------------------------------------------------------
#  Step 3 - correlate HNS endpoint -> VFP port + show rules
# ------------------------------------------------------------
function Show-VfpWiring {
    param([string]$PodId)
    Write-Section "HNS endpoint -> VFP port mapping"

    Start-Sleep 2
    # The sandbox's endpoint is the most recently created one on our network.
    $net = Get-HnsNetwork -ErrorAction SilentlyContinue | Where-Object Name -eq $NetworkName
    $eps = @(Get-HnsEndpoint -ErrorAction SilentlyContinue |
        Where-Object { $net -and $_.VirtualNetwork -eq $net.Id })
    if (-not $eps.Count) { $eps = @(Get-HnsEndpoint -ErrorAction SilentlyContinue) }

    if (-not $eps.Count) {
        Write-Host "  No HNS endpoints found. The pod may use an isolated UVM endpoint still initializing." -ForegroundColor Yellow
        return
    }

    Write-Host "  HNS endpoints on '$NetworkName':"
    $eps | Select-Object Name, IPAddress, MacAddress, State |
        Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }

    $ep = $eps | Select-Object -Last 1
    $epMacKey = ConvertTo-MacKey $ep.MacAddress
    Write-Host "  Using endpoint '$($ep.Name)' (IP $($ep.IPAddress), MAC $($ep.MacAddress))."

    # On l2bridge, program the host-side local-delivery route+neighbor so this
    # pod is reachable same-host without a control plane (no-op for NAT/overlay).
    Set-L2BridgeLocalDelivery -Network $net -Endpoint $ep

    # Show the policies HNS attached to the endpoint (these become VFP rules).
    if ($ep.PSObject.Properties['Policies'] -and $ep.Policies) {
        Write-Host "  HNS endpoint policies (programmed into VFP):"
        ($ep.Policies | ConvertTo-Json -Depth 6) -split "`n" | ForEach-Object { Write-Host "    $_" }
    }

    $ports, $rawPorts = Get-VfpSwitchPort
    $match = $ports | Where-Object { $_.MacKey -and $_.MacKey -eq $epMacKey } | Select-Object -First 1

    if (-not $match) {
        Write-Host "  Could not match endpoint MAC to a VFP port by MAC. All VFP vmswitch ports:" -ForegroundColor Yellow
        $rawPorts | ForEach-Object { Write-Host "    $_" }
        return
    }

    Write-Section "VFP port $($match.PortName)  (switch '$($match.Switch)', MAC $($match.Mac))"
    Write-Host "  --- port state (vfpctrl /port <id> /get-port-state) ---"
    Invoke-VfpPort -PortName $match.PortName -VfpCommand '/get-port-state' | ForEach-Object { Write-Host "    $_" }

    Write-Host "  --- VFP layers/spaces (vfpctrl /port <id> /list-space) ---"
    Invoke-VfpPort -PortName $match.PortName -VfpCommand '/list-space' | ForEach-Object { Write-Host "    $_" }

    Write-Host "  --- VFP rules programmed by HNS (vfpctrl /port <id> /list-rule) ---"
    Invoke-VfpPort -PortName $match.PortName -VfpCommand '/list-rule' | ForEach-Object { Write-Host "    $_" }
}

# ------------------------------------------------------------
#  Main
# ------------------------------------------------------------
Write-Host "New-VfpPod : pod='$PodName' network='$NetworkName' isolation=$(if ($ProcessIsolation) {'process'} else {'hyper-v'})" -ForegroundColor Green

Test-Prerequisites
$podId = New-PodSandbox
$ctrId = $null
if (-not $SandboxOnly) { $ctrId = New-PodContainer -PodId $podId }
Show-VfpWiring -PodId $podId

if ($Cleanup) {
    Write-Section "Cleaning up pod sandbox"
    if ($ctrId) { & $CrictlExe stop $ctrId 2>&1 | Out-Null; & $CrictlExe rm $ctrId 2>&1 | Out-Null }
    & $CrictlExe stopp $podId | Out-Null
    & $CrictlExe rmp   $podId | Out-Null
    Write-Host "  Removed pod $podId."
}
else {
    Write-Section "Done - pod left running"
    Write-Host "Pod ID       : $podId"
    if ($ctrId) { Write-Host "Container ID : $ctrId" }
    Write-Host ""
    Write-Host "Inspect:" -ForegroundColor Cyan
    Write-Host "  & '$CrictlExe' pods"
    Write-Host "  & '$CrictlExe' ps"
    Write-Host "  & '$CrictlExe' inspectp $podId"
    Write-Host "  Get-HnsEndpoint | Select Name,IPAddress,MacAddress,State"
    Write-Host "  vfpctrl /list-vmswitch-port"
    if ($ctrId) {
        Write-Host ""
        Write-Host "Exec into the container:" -ForegroundColor Cyan
        Write-Host "  & '$CrictlExe' exec -it $ctrId cmd"
    }
    Write-Host ""
    Write-Host "Remove when done:" -ForegroundColor Cyan
    Write-Host "  .\Remove-VfpPod.ps1 $PodName"
}
