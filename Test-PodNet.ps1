<#
.SYNOPSIS
  Diagnoses l2bridge pod connectivity INSIDE the guest VM.
  Run directly in the guest (elevated PowerShell), e.g. from C:\scripts\:
      .\Test-PodNet.ps1

  Checks:
   1. Whether the on-disk CNI conflist still contains the bad VXLAN SDNRoute/NeedEncap.
   2. Each HNS endpoint's IP / MAC / applied policies.
   3. Whether gateway 10.244.0.1 is plumbed on any host interface.
   4. sender -> listener (pod-to-pod) and sender -> 8.8.8.8 (internet) reachability.

  NOTE: In HNS l2bridge the gateway .1 is a pseudo-gateway and frequently does
  NOT answer ICMP even when routing works. The meaningful tests are
  pod-to-pod and pod-to-internet, NOT ping to .1.
#>

[CmdletBinding()]
param(
    [string]$CrictlExe        = 'C:\Tools\bin\crictl.exe',
    [string]$CniConfDir       = 'C:\Program Files\containerd\cni\conf',
    [string]$HnsModule        = 'C:\Program Files\containerd\cni\bin\hns.psm1',
    [string]$RuntimeEndpoint  = 'npipe:////./pipe/containerd-containerd',
    [string]$SenderName       = 'sender',
    [string]$ListenerName     = 'listener'
)

$ErrorActionPreference = 'Continue'
$ep = @('--runtime-endpoint', $RuntimeEndpoint, '--image-endpoint', $RuntimeEndpoint)
function Section($t){ Write-Host "`n==================== $t ====================" -ForegroundColor Cyan }

Import-Module $HnsModule -ErrorAction SilentlyContinue
try { Import-Module HostNetworkingService -ErrorAction SilentlyContinue } catch {}

Section "1. On-disk CNI conflist (FIX = no SDNRoute / NeedEncap for l2bridge)"
$conf = Get-ChildItem $CniConfDir -Filter '*.conflist' -ErrorAction SilentlyContinue
foreach ($c in $conf) {
    Write-Host "  File: $($c.FullName)"
    $txt = Get-Content $c.FullName -Raw
    $txt
    if ($txt -match 'SDNRoute' -or $txt -match 'NeedEncap') {
        Write-Host "  >>> STILL CONTAINS SDNRoute/NeedEncap  -> installer NOT re-run. Re-run Install-ContainerdHnsVfp.ps1." -ForegroundColor Red
    } else {
        Write-Host "  >>> OK: no encap route in conflist." -ForegroundColor Green
    }
}

Section "2. HNS endpoints (IP / MAC / Policies) - look for VXLAN/RouteEncap"
$eps = Get-HnsEndpoint -ErrorAction SilentlyContinue
foreach ($e in $eps) {
    Write-Host "  ---- $($e.Id) ----"
    Write-Host "  IP      : $($e.IPAddress)"
    Write-Host "  MAC     : $($e.MacAddress)"
    Write-Host "  Gateway : $($e.GatewayAddress)"
    $polJson = $e.Policies | ConvertTo-Json -Depth 8
    Write-Host "  Policies: $polJson"
    if ($polJson -match 'VXLAN' -or $polJson -match 'Encap' -or $polJson -match 'SDNRoute' -or $polJson -match 'RouteEncap') {
        Write-Host "  >>> This endpoint has an ENCAP policy (bad for l2bridge)." -ForegroundColor Red
    }
}

Section "3. Host interfaces carrying 10.244.0.x (is gateway .1 plumbed?)"
Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -like '10.244.0.*' } |
    Select-Object IPAddress, InterfaceAlias, InterfaceIndex | Format-Table -Auto

Section "4. Pods / containers"
& $CrictlExe @ep pods 2>$null
& $CrictlExe @ep ps 2>$null

$senderCid = (& $CrictlExe @ep ps --name $SenderName --state Running -q 2>$null | Select-Object -First 1)
Write-Host "  senderCid = $senderCid"
if (-not $senderCid) { Write-Host "  No running '$SenderName' container; aborting ping tests." -ForegroundColor Yellow; return }

# Resolve listener IP from its endpoint (match by running container -> pod -> endpoint IP).
$listenerIp = $null
$lcid = (& $CrictlExe @ep ps --name $ListenerName --state Running -q 2>$null | Select-Object -First 1)
if ($lcid) {
    # Pull the listener's IPv4 straight from its ipconfig and regex the pod-subnet
    # address off the "IPv4 Address" line. (The old `tokens=14` parse was brittle -
    # the dotted-leader count shifts, so it silently returned nothing and the
    # pod-to-pod test below was skipped entirely.) Exclude the gateway .1.
    $lipRaw = & $CrictlExe @ep exec $lcid cmd /c "ipconfig" 2>$null
    $listenerIp = $lipRaw |
        Where-Object { $_ -match 'IPv4 Address' -and $_ -match '(10\.244\.0\.\d+)' } |
        ForEach-Object { $Matches[1] } |
        Where-Object { $_ -ne '10.244.0.1' } |
        Select-Object -First 1
    if (-not $listenerIp) {
        # Fallback: resolve from the listener's HNS endpoint IP.
        $listenerIp = ($eps | Where-Object { $_.IPAddress -like '10.244.0.*' -and $_.IPAddress -ne '10.244.0.1' } |
            Select-Object -Expand IPAddress -ErrorAction SilentlyContinue | Select-Object -Last 1)
    }
}
Write-Host "  listenerIp = $listenerIp"

Section "5a. sender ipconfig"
& $CrictlExe @ep exec $senderCid cmd /c "ipconfig" 2>&1

if ($listenerIp) {
    Section "5b. sender -> listener $listenerIp (pod-to-pod, the real test)"
    $p2pRaw = & $CrictlExe @ep exec $senderCid cmd /c "ping -n 3 -w 1000 $listenerIp" 2>&1
    $p2pRaw
    $script:PodToPodOk = ($p2pRaw | Out-String) -match 'Reply from'
}
else {
    Section "5b. sender -> listener (SKIPPED - could not resolve listener IP)"
    Write-Host "  Could not determine the listener pod IP. Is the 'listener' pod running?" -ForegroundColor Yellow
    Write-Host "  Check: & '$CrictlExe' $($ep -join ' ') ps ; Get-HnsEndpoint | Select IPAddress,MacAddress,State" -ForegroundColor Yellow
    $script:PodToPodOk = $null
}

Section "5c. sender -> 8.8.8.8 (internet via OutBoundNAT)"
& $CrictlExe @ep exec $senderCid cmd /c "ping -n 3 -w 1000 8.8.8.8" 2>&1

Section "5d. sender -> gateway 10.244.0.1 (may NOT answer ICMP even when healthy)"
& $CrictlExe @ep exec $senderCid cmd /c "ping -n 2 -w 1000 10.244.0.1" 2>&1

Section "5e. sender arp -a"
& $CrictlExe @ep exec $senderCid cmd /c "arp -a" 2>&1

# ---- 6. VFP port state + rules for the pod endpoints (captured) --------------
# "Destination host unreachable" + unreadable ARP for every destination usually
# means the pod's VFP switch port is fail-closed (blocked / no allow rules).
# Correlate each pod endpoint to its VFP vmswitch port by MAC and dump the port
# state + rules on the SUCCESS stream so it lands in output.log.
function ConvertTo-MacKey { param([string]$Mac) if (-not $Mac) { return '' } ($Mac -replace '[^0-9A-Fa-f]','').ToUpper() }

Write-Output ""
Write-Output "==================== 6. VFP port state + rules (pod endpoints) ===================="
$portsRaw = cmd /c "vfpctrl /list-vmswitch-port" 2>&1
$vfpPorts = @(); $cur = $null
foreach ($line in $portsRaw) {
    $tl = "$line".Trim()
    if ($tl -match '^Port name\s*:\s*(.+)$') {
        if ($cur) { $vfpPorts += $cur }
        $cur = [pscustomobject]@{ PortName = $Matches[1].Trim(); MacKey = '' }
    }
    elseif ($cur -and $tl -match '^(MAC [Aa]ddress|Mac Address)\s*:\s*(.+)$') {
        $cur.MacKey = ConvertTo-MacKey $Matches[2].Trim()
    }
}
if ($cur) { $vfpPorts += $cur }

$podEps = @($eps | Where-Object { $_.IPAddress -like '10.244.0.*' -and $_.IPAddress -ne '10.244.0.1' })
if (-not $podEps.Count) { Write-Output "  No pod endpoints (10.244.0.x) found." }
foreach ($pe in $podEps) {
    $key = ConvertTo-MacKey $pe.MacAddress
    $match = $vfpPorts | Where-Object { $_.MacKey -and $_.MacKey -eq $key } | Select-Object -First 1
    Write-Output ""
    Write-Output "  ---- endpoint IP $($pe.IPAddress)  MAC $($pe.MacAddress) ----"
    if (-not $match) { Write-Output "  (no VFP vmswitch port matched this MAC)"; continue }
    Write-Output "  VFP port: $($match.PortName)"
    Write-Output "  --- /get-port-state (look for Blocked: TRUE) ---"
    (cmd /c "vfpctrl /port $($match.PortName) /get-port-state" 2>&1) | ForEach-Object { Write-Output "    $_" }
    Write-Output "  --- /list-rule (empty => fail-closed, no HNS rules programmed) ---"
    (cmd /c "vfpctrl /port $($match.PortName) /list-rule" 2>&1) | ForEach-Object { Write-Output "    $_" }
}

# Emit a verdict on the SUCCESS stream so it is captured even with `> output.log`
# (Section headers use Write-Host, which `>` does not redirect). The only test
# that matters here is pod-to-pod: gateway .1 and 8.8.8.8 are expected to fail
# in a standalone lab (pseudo-gateway + no host NAT / control plane).
Write-Output ""
Write-Output "==================== VERDICT (pod-to-pod is the real test) ===================="
if ($script:PodToPodOk -eq $true) {
    Write-Output "RESULT: PASS - sender reached listener ($listenerIp). Pod-to-pod works."
}
elseif ($null -eq $script:PodToPodOk) {
    Write-Output "RESULT: INCONCLUSIVE - listener IP could not be resolved; pod-to-pod not tested."
}
else {
    Write-Output "RESULT: FAIL - sender could NOT reach listener ($listenerIp)."
    Write-Output "  On a standalone single host, VXLAN 'overlay' pod-to-pod needs a control plane"
    Write-Output "  (kube-proxy / Network Controller) to program each endpoint's Provider Address"
    Write-Output "  and remote routes - nothing does that here, so overlay black-holes."
    Write-Output "  Use l2bridge for single-host pod-to-pod:"
    Write-Output "    .\Remove-VfpPod.ps1 sender ; .\Remove-VfpPod.ps1 listener"
    Write-Output "    .\Install-ContainerdHnsVfp.ps1 -NetworkMode l2bridge"
    Write-Output "    .\New-VfpPod.ps1 sender ; .\New-VfpPod.ps1 listener ; .\Test-PodNet.ps1"
}

Write-Host "`nDONE." -ForegroundColor Green
