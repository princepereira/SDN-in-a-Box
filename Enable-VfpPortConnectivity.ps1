<#
.SYNOPSIS
    Unblocks a VFP port and installs a permissive ACL policy so a VM can:
      * reach other VMs on the same virtual switch,
      * reach the internet via the host compartment (host NAT/ICS gateway),
      * send/receive DHCP (v4 67/68 and v6 546/547).

.DESCRIPTION
    Designed for an INTERNAL switch scenario where the host owns the subnet
    gateway (e.g. vEthernet (IntVirtSwitch) = 192.168.100.1/24) and performs
    NAT for internet access. The VM's VFP port comes up fail-closed
    (Blocked / BlockedOnRestore = TRUE) with no layers, so all traffic is
    dropped. This script:

      1. Clears the port block (and block-on-restore so it survives restore).
      2. Adds a stateless ACL layer with a "default allow" flag.
      3. Adds OUT/IN groups (IPv4 + optional IPv6) with:
           - explicit high-priority DHCP allow rules, and
           - a low-priority allow-all rule.

    A default-allow layer plus allow-all rules means every flow the VM needs
    (VM<->VM on the switch, VM->host gateway->internet, and DHCP broadcast)
    passes through VFP. Actual internet reachability still requires NAT/ICS
    configured on the host (e.g. New-NetNat / Internet Connection Sharing) and
    a DHCP source on the subnet - VFP only stops blocking the traffic.

    Runs in DRY-RUN by default (prints commands). Use -Execute to apply.

.PARAMETER Port
    VFP port name/GUID of the VM adapter (from `vfpctrl /list-vmswitch-port`).
    Use this OR -VMName.

.PARAMETER VMName
    VM name (e.g. 'L2-Ubu26-2'). The port GUID is resolved automatically from
    `vfpctrl /list-vmswitch-port` by matching the "VM name" field. Use this OR -Port.

.PARAMETER LayerName
    ACL layer id/name. Default 'CONNECTIVITY_ACL_LAYER'.

.PARAMETER LayerPriority
    ACL layer priority. Default 100.

.PARAMETER IncludeIPv6
    Also create IPv6 OUT/IN groups + rules (DHCPv6 + allow-all). Default $true.

.PARAMETER VfpCtrl
    Path to vfpctrl.exe. Default 'vfpctrl'.

.PARAMETER Execute
    Actually run the commands. Without it, commands are only printed.

.EXAMPLE
    # Preview:
    .\Enable-VfpPortConnectivity.ps1 -Port A6553C46-9931-4DD7-9BB1-8E28F3E4ECCF

    # Apply:
    .\Enable-VfpPortConnectivity.ps1 -Port A6553C46-9931-4DD7-9BB1-8E28F3E4ECCF -Execute

.EXAMPLE
    # Resolve the port from a VM name, then apply:
    .\Enable-VfpPortConnectivity.ps1 -VMName L2-Ubu26-2 -Execute
#>

[CmdletBinding(DefaultParameterSetName = 'ByPort')]
param(
    [Parameter(ParameterSetName = 'ByPort', Mandatory = $true)]
    [string] $Port,

    [Parameter(ParameterSetName = 'ByVm', Mandatory = $true)]
    [string] $VMName,

    [string] $LayerName     = 'CONNECTIVITY_ACL_LAYER',
    [int]    $LayerPriority = 100,
    [bool]   $IncludeIPv6   = $true,
    [string] $VfpCtrl       = 'vfpctrl',
    [switch] $Execute
)

$ErrorActionPreference = 'Stop'

# Group ids
$G_V4_OUT = 'CONN_ACL_IPV4_OUT'
$G_V4_IN  = 'CONN_ACL_IPV4_IN'
$G_V6_OUT = 'CONN_ACL_IPV6_OUT'
$G_V6_IN  = 'CONN_ACL_IPV6_IN'

# Priorities (lower number = evaluated first)
$PRI_DHCP  = 100
$PRI_ALLOW = 60000

# --- helper ---------------------------------------------------------------

function Invoke-Vfp {
    param([string[]] $VfpArgs, [string] $Comment)

    $display = '{0} {1}' -f $VfpCtrl, ($VfpArgs -join ' ')
    if ($Comment) { Write-Host "  # $Comment" -ForegroundColor DarkGray }

    if ($Execute) {
        Write-Host "  $display" -ForegroundColor Cyan
        $out = & $VfpCtrl @VfpArgs 2>&1
        $ok  = ($LASTEXITCODE -eq 0) -and ($out -notmatch 'failed')
        $color = if ($ok) { 'Green' } else { 'Red' }
        ($out | Out-String).TrimEnd().Split("`n") | ForEach-Object {
            if ($_ -ne '') { Write-Host "      $_" -ForegroundColor $color }
        }
        if (-not $ok) { Write-Warning "Command reported failure: $display" }
    }
    else {
        Write-Host "  $display" -ForegroundColor Yellow
    }
}

# Resolve a VFP port name from a VM name by parsing /list-vmswitch-port.
# Matches the "VM name : <name>" field within each port block. Returns the
# "Port name : <guid>" of the matching block.
function Resolve-VfpPortByVmName {
    param([string] $Name)

    $raw = & $VfpCtrl '/list-vmswitch-port' 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "vfpctrl /list-vmswitch-port failed: $($raw | Out-String)"
    }

    $lines       = ($raw | Out-String) -split "`r?`n"
    $currentPort = $null
    $found       = @()

    foreach ($line in $lines) {
        if ($line -match '^\s*Port name\s*:\s*(.+?)\s*$') {
            $currentPort = $Matches[1].Trim()
        }
        elseif ($line -match '^\s*VM name\s*:\s*(.+?)\s*$') {
            $vm = $Matches[1].Trim()
            if ($currentPort -and $vm -and ($vm -ieq $Name)) {
                $found += [pscustomobject]@{ Port = $currentPort; Vm = $vm }
            }
        }
    }

    if ($found.Count -eq 0) {
        throw "No VFP port found for VM name '$Name'. Check 'vfpctrl /list-vmswitch-port'."
    }
    if (($found | Select-Object -ExpandProperty Port -Unique).Count -gt 1) {
        $list = ($found.Port -join ', ')
        throw "VM name '$Name' maps to multiple ports ($list). Pass -Port explicitly."
    }

    return $found[0].Port
}

# add-rule-ex "[id] [name] [proto] [src_ip] [src_prt] [dest_ip] [dest_prt] [flag] [ttl] [pri] [type] [data]"
function Add-AllowRule {
    param(
        [string] $Group,
        [string] $Id,
        [string] $Proto   = '*',
        [string] $SrcIp   = '*',
        [string] $SrcPrt  = '*',
        [string] $DestIp  = '*',
        [string] $DestPrt = '*',
        [int]    $Flag    = 1,     # 1 = terminating
        [int]    $Ttl     = 0,
        [int]    $Pri     = 60000,
        [string] $Comment = ''
    )
    $rule = @($Id, $Id, $Proto, $SrcIp, $SrcPrt, $DestIp, $DestPrt, $Flag, $Ttl, $Pri, 'allow')
    Invoke-Vfp -Comment $Comment -VfpArgs @(
        '/port', $Port, '/layer', $LayerName, '/group', $Group,
        '/add-rule-ex', ('"{0}"' -f ($rule -join ' ')))
}

# --- main -----------------------------------------------------------------

# Resolve port from VM name if -VMName was used.
if ($PSCmdlet.ParameterSetName -eq 'ByVm') {
    Write-Host "`nResolving port for VM '$VMName'..." -ForegroundColor White
    $Port = Resolve-VfpPortByVmName -Name $VMName
    Write-Host "  -> Port $Port" -ForegroundColor Green
}

Write-Host "`n=== Enable connectivity on VFP port $Port ===`n" -ForegroundColor White

# 0) Enable VFP policy on the port. Without this the port has VFP loaded but no
#    policy object, so /unblock-port and /add-layer fail with "Error (2): The
#    system cannot find the file specified." (On SDN hosts the NC/SLB agent does
#    this; on a standalone lab host we must run it ourselves.)
Write-Host "Enable VFP on port:" -ForegroundColor White
Invoke-Vfp -Comment "enable VFP policy on port" -VfpArgs @('/port', $Port, '/enable-port')

# 1) Clear blocks (durable across restore)
Write-Host "Clear port block:" -ForegroundColor White
Invoke-Vfp -Comment "unblock now"        -VfpArgs @('/port', $Port, '/unblock-port')
Invoke-Vfp -Comment "unblock on restore" -VfpArgs @('/port', $Port, '/unblock-port-on-restore')

# 2) ACL layer (stateless, default-allow flag = 1)
Write-Host "`nACL layer:" -ForegroundColor White
Invoke-Vfp -Comment "default-allow ACL layer" -VfpArgs @(
    '/port', $Port, '/add-layer',
    ('"{0} {0} stateless {1} 1"' -f $LayerName, $LayerPriority))

# 3) Groups
Write-Host "`nGroups:" -ForegroundColor White
Invoke-Vfp -Comment "IPv4 OUT" -VfpArgs @(
    '/port', $Port, '/layer', $LayerName, '/add-group',
    ('"{0} {0} out {1} * * * * * priority_based_auto_condition_opt"' -f $G_V4_OUT, $LayerPriority))
Invoke-Vfp -Comment "IPv4 IN" -VfpArgs @(
    '/port', $Port, '/layer', $LayerName, '/add-group',
    ('"{0} {0} in {1} * * * * * priority_based_auto_condition_opt"' -f $G_V4_IN, $LayerPriority))

if ($IncludeIPv6) {
    Invoke-Vfp -Comment "IPv6 OUT" -VfpArgs @(
        '/port', $Port, '/layer', $LayerName, '/add-group',
        ('"{0} {0} outv6 {1} * * * * * priority_based_auto_condition_opt"' -f $G_V6_OUT, $LayerPriority))
    Invoke-Vfp -Comment "IPv6 IN" -VfpArgs @(
        '/port', $Port, '/layer', $LayerName, '/add-group',
        ('"{0} {0} inv6 {1} * * * * * priority_based_auto_condition_opt"' -f $G_V6_IN, $LayerPriority))
}

# 4) Rules
Write-Host "`nIPv4 rules:" -ForegroundColor White
# DHCPv4 client->server (68->67) out, server->client (67->68) in
Add-AllowRule -Group $G_V4_OUT -Id 'dhcp_v4_out' -Proto 17 -SrcPrt 68 -DestPrt 67 -Pri $PRI_DHCP -Comment "DHCPv4 request out (udp 68->67)"
Add-AllowRule -Group $G_V4_IN  -Id 'dhcp_v4_in'  -Proto 17 -SrcPrt 67 -DestPrt 68 -Pri $PRI_DHCP -Comment "DHCPv4 reply in (udp 67->68)"
# allow-all (VM<->VM, VM->host gateway->internet)
Add-AllowRule -Group $G_V4_OUT -Id 'allow_all_v4_out' -Pri $PRI_ALLOW -Comment "allow all IPv4 out"
Add-AllowRule -Group $G_V4_IN  -Id 'allow_all_v4_in'  -Pri $PRI_ALLOW -Comment "allow all IPv4 in"

if ($IncludeIPv6) {
    Write-Host "`nIPv6 rules:" -ForegroundColor White
    # DHCPv6 client->server (546->547) out, server->client (547->546) in
    Add-AllowRule -Group $G_V6_OUT -Id 'dhcp_v6_out' -Proto 17 -SrcPrt 546 -DestPrt 547 -Pri $PRI_DHCP -Comment "DHCPv6 request out (udp 546->547)"
    Add-AllowRule -Group $G_V6_IN  -Id 'dhcp_v6_in'  -Proto 17 -SrcPrt 547 -DestPrt 546 -Pri $PRI_DHCP -Comment "DHCPv6 reply in (udp 547->546)"
    Add-AllowRule -Group $G_V6_OUT -Id 'allow_all_v6_out' -Pri $PRI_ALLOW -Comment "allow all IPv6 out"
    Add-AllowRule -Group $G_V6_IN  -Id 'allow_all_v6_in'  -Pri $PRI_ALLOW -Comment "allow all IPv6 in"
}

# --- epilogue -------------------------------------------------------------

if (-not $Execute) {
    Write-Host "`n[DRY-RUN] No changes applied. Re-run with -Execute to apply." -ForegroundColor White
}
else {
    Write-Host "`nDone. Verify with:" -ForegroundColor White
    Write-Host "  $VfpCtrl /get-port-state /port $Port" -ForegroundColor Gray
    Write-Host "  $VfpCtrl /port $Port /list-rule"      -ForegroundColor Gray
}

Write-Host "`nReminder: internet access also needs host-side NAT for the subnet, e.g.:" -ForegroundColor White
Write-Host "  New-NetNat -Name IntVirtNat -InternalIPInterfaceAddressPrefix 192.168.100.0/24" -ForegroundColor Gray
Write-Host "  (and a DHCP source, or set a static IP + gateway 192.168.100.1 in the VM)" -ForegroundColor Gray
