# Enable-VfpPortConnectivity.ps1 — (re)apply VFP connectivity policy on a port

Unblocks a **VFP port** and installs a permissive ACL policy so a VM can reach
other VMs on the same virtual switch, reach the internet via the host
compartment (host NAT/ICS gateway), and send/receive **DHCP** (v4 67/68 and v6
546/547).

Use it in two situations:

- **First-time enablement** on a standalone lab host that has no NC/SLB agent to
  program the port (`Create-L2Vm-Linux.ps1` calls this automatically).
- **Recovery** — when a port **loses its VFP rules** (comes up fail-closed with
  `Blocked`/`BlockedOnRestore = TRUE` and no layers, e.g. after a vNIC re-attach
  or a reboot). Re-run this script to restore connectivity **without rebuilding
  the VM**.

`Create-L1Vm-Windows.ps1` copies this script into the L1 guest at `C:\scripts`.

> Lab/test automation tool. It only stops VFP from blocking traffic — actual
> internet reachability still needs host-side NAT/ICS for the subnet and a DHCP
> source (or a static IP + gateway in the VM).

---

## Usage

Runs in **dry-run by default** (prints the `vfpctrl` commands). Add `-Execute`
to apply.

```powershell
# Preview (dry-run) — resolve the port from the VM name:
C:\scripts\Enable-VfpPortConnectivity.ps1 -VMName L2-Ubu26-2

# Apply, resolving the port from the VM name:
C:\scripts\Enable-VfpPortConnectivity.ps1 -VMName L2-Ubu26-2 -Execute

# Apply against an explicit port GUID (from: vfpctrl /list-vmswitch-port):
C:\scripts\Enable-VfpPortConnectivity.ps1 -Port A6553C46-9931-4DD7-9BB1-8E28F3E4ECCF -Execute
```

---

## Parameters

| Parameter        | Type     | Default                   | Description                                                                                  |
| ---------------- | -------- | ------------------------- | -------------------------------------------------------------------------------------------- |
| `-Port`          | string   | —                         | VFP port name/GUID of the VM adapter (from `vfpctrl /list-vmswitch-port`). Use this **or** `-VMName`. |
| `-VMName`        | string   | —                         | VM name (e.g. `L2-Ubu26-2`); the port GUID is resolved automatically by matching the "VM name" field. Use this **or** `-Port`. |
| `-LayerName`     | string   | `CONNECTIVITY_ACL_LAYER`  | ACL layer id/name.                                                                            |
| `-LayerPriority` | int      | `100`                     | ACL layer priority.                                                                          |
| `-IncludeIPv6`   | bool     | `$true`                   | Also create IPv6 OUT/IN groups + rules (DHCPv6 + allow-all).                                  |
| `-VfpCtrl`       | string   | `vfpctrl`                 | Path to `vfpctrl.exe`.                                                                        |
| `-Execute`       | switch   | (off)                     | Actually run the commands. Without it, commands are only printed (dry-run).                   |

---

## What the script does (in order)

1. **Enable VFP policy on the port** — `/enable-port`. Without this the port has
   VFP loaded but no policy object, so `/unblock-port` and `/add-layer` fail with
   `Error (2): The system cannot find the file specified.` On SDN hosts the
   NC/SLB agent does this; on a standalone lab host the script must.
2. **Clear the port block** — `/unblock-port` and `/unblock-port-on-restore` (so
   it survives a restore).
3. **Add a stateless ACL layer** with a "default allow" flag.
4. **Add OUT/IN groups** (IPv4 + optional IPv6).
5. **Add rules** per group:
   - explicit high-priority **DHCP allow** rules (v4 68↔67, v6 546↔547), and
   - a low-priority **allow-all** rule.

A default-allow layer plus allow-all rules means every flow the VM needs
(VM↔VM on the switch, VM→host gateway→internet, and DHCP broadcast) passes
through VFP.

---

## Verify

```powershell
vfpctrl /get-port-state /port <PORT-GUID>
vfpctrl /port <PORT-GUID> /list-rule
vfpctrl /port <PORT-GUID> /list-layer
```

---

## Notes / Troubleshooting

- **`Error (2)` from `vfpctrl`** — the `vfpext` service isn't running (reboot the
  L1 node so the VFP driver starts), or the port GUID is stale. A port's VFP GUID
  changes on every vNIC re-attach — re-fetch it from `vfpctrl /list-vmswitch-port`
  after any reboot.
- **`-VMName` maps to multiple ports** — pass `-Port <GUID>` explicitly.
- **Internet still fails after applying** — VFP is no longer blocking; ensure
  host-side NAT for the subnet exists, e.g.:
  ```powershell
  New-NetNat -Name IntVirtNat -InternalIPInterfaceAddressPrefix 192.168.100.0/24
  ```
  and a DHCP source on the subnet (or set a static IP + gateway `192.168.100.1`
  in the VM).
- The authoritative, runnable script is **`Enable-VfpPortConnectivity.ps1`**
  (kept in sync with this document).
