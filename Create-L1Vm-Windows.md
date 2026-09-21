# Create-L1Vm-Windows.ps1 — L1 Windows Server SDN/VFP host

Creates and fully auto-configures an **L1 Windows Server VM** in Hyper-V that is
itself a Hyper-V + SDN host, ready to run nested **L2 Ubuntu** VMs
(see `Create-L2Vm-Linux.md`).

The script builds the VM from a winbuilds VHDX (or an explicit `.vhdx`), injects
an `unattend.xml` for an unattended first boot, then drives the guest over
**PowerShell Direct** to install SDN roles, enable the **VFP switch extension**,
create an internal NAT switch, pre-stage the **Ubuntu cloud image**, install
**MobaXterm**, and copy the L2 creation script into the guest.

> This is a lab/test automation tool. Passwords live in plain text inside the
> answer file (standard for unattended setup); do not use for production images.

---

## VM specification

| Setting                      | Value                                   |
| ---------------------------- | --------------------------------------- |
| VM Name                      | `L1-GeCurNv-2025` (default)             |
| Generation                   | Generation 2                            |
| RAM                          | 16384 MB (16 GB), static                |
| Dynamic Memory               | False                                   |
| Network Connection           | External virtual switch (auto-detected) |
| Virtual Hard Disk            | Per-VM **differencing** child of the base `.vhdx` |
| Enhanced Session Mode        | Allowed (True)                          |
| Secure Boot                  | Disabled                                |
| Virtual Processors           | 8                                       |
| Nested Virtualization        | Enabled (`ExposeVirtualizationExtensions` + MAC spoofing) |

---

## Prerequisites

- Run in an **elevated** PowerShell session on a Hyper-V host.
- Access to `\\winbuilds\release` when using `-Branch` (otherwise supply a `.vhdx`).
- The guest image must be Windows Server 2016+ with Integration Services (for
  PowerShell Direct). Internet access **inside the guest** is needed to download
  the Ubuntu cloud image and MobaXterm.

---

## Parameters

| Parameter          | Type   | Description                                                                                       |
| ------------------ | ------ | ------------------------------------------------------------------------------------------------- |
| `-Branch`          | string | Winbuilds branch, e.g. `ge_current_directiof_nv`. The **latest** vhdx for the branch is robocopied to `C:\VHDs` and used as the base. **Required unless `-VHDXPath` is supplied.** |
| `-L1VMName`        | string | Optional. VM name. Defaults to `L1-GeCurNv-2025`.                                                  |
| `-VHDXPath`        | string | Optional. Explicit path to an existing `.vhdx`. Used directly; `-Branch` is ignored.              |
| `-RemoteVHDXPath`  | string | Optional. A `.vhdx` (local or on a share) first robocopied into `C:\VHDs`, then used as the base. Takes precedence over `-Branch`; ignored when `-VHDXPath` is set. |

## Constants (edit at the top of the script)

| Constant                        | Default                                   | Purpose                                                            |
| ------------------------------- | ----------------------------------------- | ------------------------------------------------------------------ |
| `$L1VmAdminPassword`            | `Admin@123`                               | Administrator password. When set, `unattend.xml` is injected and guest setup runs. |
| `$Locale` / `$TimeZone` / `$KeyboardLayout` | `en-US` / `India Standard Time` / `0409:00000409` | Guest locale, time zone, keyboard.                     |
| `$AutoLogonCount`               | `1`                                       | Times to auto-logon Administrator (`0` = off).                     |
| `$ComputerName`                 | `$null`                                   | Guest hostname; `$null` derives from VM name (≤15 chars).          |
| `$EnableNestedVirtualization`   | `$true`                                   | Expose virtualization extensions + MAC spoofing.                   |
| `$SkipGuestSetup`               | `$false`                                  | Skip all in-guest configuration.                                   |
| `$LicenseGuest`                 | `$true`                                   | If the guest is unlicensed (RFM), install the edition's public GVLK (`slmgr /ipk`) + best-effort `/ato` so roles can install. No purchased/secret key is used. |
| `$GuestGvlkMap` / `$GuestGvlkDefault` | Datacenter/Standard GVLKs / Datacenter | Public generic KMS-client keys; edition auto-detected in-guest.   |
| `$GuestRolesFeatures`           | Hyper-V, NetworkController, NPAS, Containers, Telnet-Client, NetworkVirtualization | Roles/features installed in the guest (unavailable names are skipped). **DHCP is intentionally not installed.** |
| `$GuestSwitchName`              | `Ethernet`                                | External vSwitch created inside the guest.                         |
| `$VfpExtensionName`             | `Microsoft Azure VFP Switch Extension`    | Switch extension enabled on the guest vSwitches.                   |
| `$CreateInternalSwitch`         | `$true`                                   | Create the internal NAT switch for nested L2 VMs.                  |
| `$IntSwitchName`                | `IntVirtSwitch`                           | Internal switch name.                                              |
| `$IntSwitchGatewayIP`           | `192.168.100.1`                           | Gateway IP assigned to the internal switch vNIC.                   |
| `$IntSwitchPrefixLength`        | `24`                                      | Internal subnet prefix length.                                     |
| `$IntSwitchSubnetPrefix`        | `192.168.100.0/24`                        | Internal subnet (for `New-NetNat`).                                |
| `$IntSwitchNatName`             | `UbuntuNat`                               | NetNat name for the internal subnet.                               |
| `$GuestReadyTimeoutMinutes`     | `30`                                      | Minutes to wait for the guest via PowerShell Direct.              |
| `$DownloadUbuntuImage`          | `$true`                                   | Download the Ubuntu **cloud image** inside the guest.             |
| `$UbuntuImageUrl`               | `.../releases/26.04/release/ubuntu-26.04-server-cloudimg-amd64.img` | Ubuntu 26.04 cloud image (qcow2). |
| `$UbuntuImageDir`               | `C:\ISOs`                                 | Destination for the cloud image inside the guest.                 |
| `$InstallMobaXterm`             | `$true`                                   | Install MobaXterm (portable) inside the guest and add it to PATH. |
| `$MobaXtermUrl`                 | `MobaXterm_Portable_v26.4.zip`            | Portable MobaXterm download URL.                                   |
| `$MobaXtermDir`                 | `C:\Tools\MobaXterm`                      | Portable install location inside the guest.                       |
| `$MobaXtermBinDir`              | `C:\Tools\bin`                            | Bin dir added to the machine PATH; holds the `mobaxterm` launcher. |
| `$GuestScriptsDir`              | `C:\scripts`                              | Destination folder inside the guest for copied host scripts.      |
| `$HostFilesToCopy`              | `Create-L2Vm-Linux.ps1`, `Enable-VfpPortConnectivity.ps1` | Host files copied into the guest (relative names resolve to the script folder). |

---

## What the script does (in order)

1. **Resolve the base VHDX** — `-VHDXPath` (used directly), `-RemoteVHDXPath`
   (robocopied into `C:\VHDs`), or the **latest** build for `-Branch` from
   `\\winbuilds\release`. The Desktop-Experience Datacenter image is preferred and
   Server Core is avoided (`$PreferVhdxIncludePattern=serverdatacenter`,
   `$PreferVhdxExcludePattern=core`).
2. **Create a per-VM differencing child disk** at `C:\VHDs\<VMName>\<VMName>.vhdx`
   parented to the base, so the base is never locked and can be reused concurrently.
3. **Inject `unattend.xml`** into the child disk (when `$L1VmAdminPassword` is set)
   for a fully unattended first boot: Administrator password, computer name, time
   zone, locales/keyboard, OOBE skips, auto-logon, and enabling RDP.
4. **Auto-detect or create the External virtual switch**, then **create the Gen-2 VM**
   (16 GB static RAM, child VHDX, external switch).
5. **Apply settings**: disable Dynamic Memory, allow Enhanced Session Mode, disable
   Secure Boot, set 8 vCPUs.
6. **Enable nested virtualization** on the host (`ExposeVirtualizationExtensions`
   + `MacAddressSpoofing On`) while the VM is off, then **start the VM**.
7. **In-guest setup over PowerShell Direct** (`Invoke-Command -VMName`, over VMBus,
   no network required), when `$L1VmAdminPassword` is set and `-SkipGuestSetup` is
   not:
   0. **Ensure the guest is Licensed** — clears Reduced Functionality Mode (which
      would make `Install-WindowsFeature` refuse every role) by installing the
      detected edition's public GVLK and best-effort activating.
   1. **Install roles/features** (`-IncludeManagementTools`): Hyper-V, Network
      Controller, NPAS, Network Virtualization, Containers, Telnet Client. Each is
      attempted independently; unavailable names are skipped with a warning.
      **DHCP is not installed.** The guest is only driven once it is *settled*
      (host-side `Running`, minimum uptime, several consecutive good probes) so a
      queued first-boot/servicing reboot can't make the install fail. If a role
      still hits a transient *"A system shutdown is in progress"* / *"not in
      running state"*, only the not-yet-installed roles are retried (up to 4
      attempts) after waiting for the guest to settle; the script throws if they
      never install rather than silently continuing.
   2. **Reboot the guest** automatically if role installation requires it (Hyper-V does).
   3. **Create the external vSwitch** (`Ethernet`) bound to the guest's up NIC.
   4. **Enable the VFP switch extension** on that vSwitch (verified with retries).
   5. **Reboot the guest again** so the **VFP forwarding driver (`vfpext`)
      actually starts** before any nested ports exist. *This is required:* until
      the node reboots, `vfpctrl` on L2 ports fails with `Error (2)` and rules
      cannot be programmed. The script waits for the guest to come back before
      proceeding.
   6. **Create the internal NAT switch** (`IntVirtSwitch`): internal vSwitch,
      gateway `192.168.100.1/24` on its vNIC, VFP extension enabled (verified),
      `New-NetNat` for `192.168.100.0/24`, plus inbound **ICMP echo** firewall
      rules so L2 guests can ping the gateway.
   7. **Download the Ubuntu cloud image** (`$UbuntuImageUrl`) into `$UbuntuImageDir`
      (default `C:\ISOs`) inside the guest (skipped if already present). The L2
      script converts this qcow2 image to VHDX and boots it directly.
   8. **Install MobaXterm (portable)** inside the guest into `$MobaXtermDir`,
      create a `mobaxterm.cmd` launcher in `$MobaXtermBinDir`, and add that dir to
      the **machine PATH** (skipped if already present). The L2 script then only
      adds a per-VM SSH session.
   9. **Copy host helper scripts** (`$HostFilesToCopy`, e.g. `Create-L2Vm-Linux.ps1`
      and `Enable-VfpPortConnectivity.ps1`) into `$GuestScriptsDir` (default
      `C:\scripts`) via `Copy-Item -ToSession`. `Enable-VfpPortConnectivity.ps1`
      lets you re-apply VFP connectivity policy on a port if it ever loses its
      rules (see below).

---

## VHDX acquisition & base-image reuse

- **Winbuilds source (example):**
  `\\winbuilds\release\<Branch>\<build>\amd64fre\vhdx\vhdx_server_serverdatacenter_en-us_vl\...vhdx`
- **Local directory:** `C:\VHDs` (created if missing). Only paths containing a
  `vhdx` segment are copied. Robocopy exit codes 0–7 = success; 8+ = failure.
- The base VHDX is **never** attached/written directly. Each VM gets a
  **differencing child** (`New-VHD -Differencing -ParentPath <base>`); the
  `unattend.xml` is injected into the child and the VM boots from it, leaving the
  base opened read-only.
- The base must remain in place while its child disks exist — deleting/moving it
  breaks any VM built on top.

---

## Examples

```powershell
# Use an explicit, already-local vhdx directly
.\Create-L1Vm-Windows.ps1 -VHDXPath "C:\VHDs\my-image.vhdx" -L1VMName "L1-GeCur-2025"

# Copy a vhdx (local or share) into C:\VHDs first, then build from the local copy
.\Create-L1Vm-Windows.ps1 -RemoteVHDXPath "\\share\path\image.vhdx" -L1VMName "L1-GeCur-2025"

# Always copy the latest vhdx for the branch from winbuilds, then build
.\Create-L1Vm-Windows.ps1 -Branch ge_current_directiof_nv -L1VMName "L1-GeCur-2025"
```

---

## Verify

```powershell
# Host-side VM settings
Get-VM -Name $vmName | Format-List Name, Generation, State
Get-VMMemory     -VMName $vmName | Format-List DynamicMemoryEnabled, Startup
Get-VMFirmware   -VMName $vmName | Format-List SecureBoot
Get-VMProcessor  -VMName $vmName | Format-List Count, ExposeVirtualizationExtensions
Get-VMNetworkAdapter -VMName $vmName | Format-List Name, SwitchName, MacAddressSpoofing

# Inside the guest (after setup)
Get-WindowsFeature | Where-Object Installed | Select-Object Name
Get-VMSwitch | Select-Object Name, SwitchType
Get-VMSwitchExtension -VMSwitchName IntVirtSwitch | Select-Object Name, Enabled
Get-Service vfpext | Select-Object Name, Status
Get-NetNat | Select-Object Name, InternalIPInterfaceAddressPrefix
Test-Path C:\ISOs\ubuntu-26.04-server-cloudimg-amd64.img
Test-Path C:\Tools\MobaXterm
```

---

## Recovering lost VFP rules on a port

`Enable-VfpPortConnectivity.ps1` is copied into the guest at `C:\scripts`. If a
VFP port ever **loses its rules** (e.g. after a vNIC re-attach, a reboot, or the
port coming up fail-closed with no layers), re-apply a permissive connectivity
policy with it — no need to rebuild the VM:

```powershell
# From C:\scripts inside the L1 guest — resolve the port by VM name and apply:
C:\scripts\Enable-VfpPortConnectivity.ps1 -VMName L2-Ubu26-2 -Execute

# Or target a specific port GUID (from: vfpctrl /list-vmswitch-port):
C:\scripts\Enable-VfpPortConnectivity.ps1 -Port <PORT-GUID> -Execute
```

Omit `-Execute` for a dry run that only prints the `vfpctrl` commands. See
`Enable-VfpPortConnectivity.md` for details.

---

## Notes

- `16GB` = `16384` MB, matching the requirement exactly.
- If no External switch exists, one is created automatically, bound to the fastest
  active physical adapter. List switches: `Get-VMSwitch | Select Name, SwitchType`.
- `Set-VMHost -EnableEnhancedSessionMode $true` is the host-wide
  "Allow Enhanced Session Mode" policy.
- **Nested virtualization** requires static memory (set) and the VM to be **off**
  when `ExposeVirtualizationExtensions` is applied — the script does both.
- **The pre-internal-switch reboot is essential** for VFP: enabling the extension
  only registers `vfpext`; the driver starts on the next boot, and only then can
  `vfpctrl` program the nested L2 ports.
- `NetworkVirtualization` is not present on all builds; if absent it is skipped
  and the rest of the install continues.
- **Security:** the Administrator password is stored in plain text in
  `\Windows\Panther\unattend.xml` inside the VHDX (standard for lab automation;
  Windows redacts it after setup). Avoid for production/shared images.
- The authoritative, runnable script is **`Create-L1Vm-Windows.ps1`** (kept in
  sync with this document).
