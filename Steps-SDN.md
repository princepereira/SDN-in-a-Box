Steps to Bringup L1 VM with Hyper-V and VFP Support
===================================================

Path to copy: \\winbuilds\release\ge_current_directiof_nv\26672.1000.260813-1700\amd64fre\vhdx\vhdx_server_serverdatacenter_en-us_vl\26672.1000.amd64fre.ge_current_directiof_nv.260813-1700_server_serverdatacenter_en-us_vl.vhdx

Hyper-V -> New -> VM Name: L1-GeCurNv-2025 -> Generation 2 -> Ram: 16384 -> use Dynamic Memory(False)-> Connection: External virtual Switch -> Use an existing virtual Hard Disk -> Select .VHDX -> Finish

Hyper-V -> Hyper-V Settings -> Enhanced Session Mode Policy > Allow Enhanced Session Mode (True) -> Ok

Hyper-V -> Settings -> Security -> Enable Secure Boot (False)
	            -> Processor -> Number of virtual Processors: 8 -> Ok

Password: Administrator/Admin@123

Shutdown/Turn Off VM


Enable Nested Virtualization on the Host

Stop-VM <VMName>

Set-VMProcessor -VMName <VMName> -ExposeVirtualizationExtensions $true
Eg: Set-VMProcessor -VMName L1-GeCurNv-2025 -ExposeVirtualizationExtensions $true

Start-VM <VMName>

Verify

Get-VMProcessor -VMName <VMName> | fl ExposeVirtualizationExtensions
Eg: Get-VMProcessor -VMName L1-GeCurNv-2025 | fl ExposeVirtualizationExtensions


Start VM
Enter Password: Admin@123
Server Manager -> Dashboard -> Add Roles and Features -> Role Based or Feature Based Installation -> Select Server from the Server Pool -> Roles: Hype-V, Network Controller, DHCP Server, Network Policy and Access Services -> Add Features -> Next -> Features: Network Virtualization, Containers, Telnet Client -> Next -> Virtual Switches: Ethernet -> Install -> Close after installation is completed.

Restart the node and reconnect

L1-VM -> Hyper-V Manager - > Select VM -> Virtual Switch Manager -> Select: Microsoft Hyper-V network Adapter - Virtual Switch  -> Extensions -> Select: Microsoft Azure VFP Switch Extension -> Apply -> OK


Steps to create L2 Ubuntu VM on L1 Windows VM Hyper-V

Open a browser in L1 VM and Download Ubuntu image

Loc: https://ubuntu.com/download/server , Select "Ubuntu 26.04 LTS", "Intel or AMD 64-bit architecture", "Download". This downloads : ubuntu-26.04-live-server-amd64.iso


DHCP Server
============

Get-Service dhcpserver
Add-DhcpServerv4Scope -Name "IntVirtSwitch" -StartRange 192.168.100.10 -EndRange 192.168.100.200 -SubnetMask 255.255.255.0 -State Active
Set-DhcpServerv4OptionValue -ScopeId 192.168.100.0 -Router 192.168.100.1
Get-DhcpServerv4Scope


Create an Internal Switch:

New-VMSwitch -Name IntVirtSwitch -SwitchType Internal
New-NetIPAddress -IPAddress 192.168.100.1 -PrefixLength 24 -InterfaceAlias "vEthernet (IntVirtSwitch)"
Enable-VMSwitchExtension -VMSwitchName IntVirtSwitch -Name "Microsoft Azure VFP Switch Extension"
New-NetNat -Name UbuntuNat -InternalIPInterfaceAddressPrefix 192.168.100.0/24
Get-NetNat

New-NetFirewallRule -DisplayName "Allow ICMPv4-In" -Protocol ICMPv4 -IcmpType 8 -Direction Inbound -Action Allow


L1-VM -> Hyper-V Manager - > Select VM -> New Virtual Machine -> Name: L2-Ubu26-1 -> Generation 2 -> RAM: 4096MB -> Select: Microsoft Hyper-V network Adapter - Virtual Switch -> Create a Virtual Hard Disk -> Install an Operating System from a bootable image file -> Browse and select ubuntu ISO from Downloads -> Next -> Finish

L1-VM -> Hyper-V Manager - > Select VM -> Select L2 Ubuntu VM -> Hyper-V Settings -> Enhanced Session Mode Policy > Allow Enhanced Session Mode (True) -> Ok

L1-VM -> Hyper-V Manager - > Select VM -> Select L2 Ubuntu VM -> Hyper-V Settings -> Settings -> Security -> Enable Secure Boot (False) -> OK

Start and connect L2 Ubuntu VM -> Try or Install Ubuntu Server -> Always use maximize mode -> Name: prince, Servers Name: ppereira, Username: ppereira, Password: ppereira@123, Hit: Tab, Done -> Install OpenSSH Server: Select: Spacebar ->
Tab: Done -> Tab: Reboot Now


ON Linux Guest VM
===================

# sudo networkctl renew eth0
sudo ip addr add 192.168.100.10/24 dev eth0
sudo ip link set eth0 up
sudo ip route add default via 192.168.100.1 dev eth0
sudo ip addr show eth0

echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf

sudo apt update
sudo apt install xrdp
sudo systemctl enable xrdp
sudo systemctl start xrdp

# Python
sudo apt install -y python3 python3-pip

# tcpdump
sudo apt install -y tcpdump

# ifconfig
sudo apt install -y net-tools

# useful networking tools
sudo apt install -y iproute2 traceroute netcat-openbsd dnsutils



Automation Scripts (copied into the L1 VM)
==========================================

Create-L1Vm-Windows.ps1 copies its helper scripts into the L1 guest at
C:\scripts (created automatically):

  C:\scripts\Create-L2Vm-Linux.ps1          - create nested L2 Ubuntu VMs
  C:\scripts\Enable-VfpPortConnectivity.ps1 - (re)apply VFP connectivity policy on a port

See Create-L1Vm-Windows.md, Create-L2Vm-Linux.md, and
Enable-VfpPortConnectivity.md for full details.


Recovering lost VFP rules on a port
===================================

If a VFP port loses its VFP rules (e.g. the port comes up fail-closed with no
layers after a vNIC re-attach or a reboot), you do NOT need to rebuild the VM.
Re-apply a permissive connectivity policy (enable/unblock the port + ACL
layer/group/allow rules for IPv4/IPv6 and DHCP) with the copied helper script:

  # Resolve the port automatically from the VM name and apply:
  C:\scripts\Enable-VfpPortConnectivity.ps1 -VMName L2-Ubu26-2 -Execute

  # Or target a specific port GUID (from: vfpctrl /list-vmswitch-port):
  C:\scripts\Enable-VfpPortConnectivity.ps1 -Port <PORT-GUID> -Execute

Omit -Execute for a dry run that only prints the vfpctrl commands.

Verify afterwards:

  vfpctrl /get-port-state /port <PORT-GUID>
  vfpctrl /port <PORT-GUID> /list-rule

Note: if vfpctrl returns Error (2), the vfpext service isn't running (reboot the
L1 node so the VFP driver starts) or the port GUID is stale (re-fetch it from
vfpctrl /list-vmswitch-port).


