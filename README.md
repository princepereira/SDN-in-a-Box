# SDNLabSetup

Lab automation for standing up a nested **SDN / VFP** test environment on Hyper-V.

Topology: **L0** (physical Hyper-V host) → **L1** (nested Windows Server guest, runs
containerd + HNS + VFP) → **pods** (Hyper-V-isolated Windows containers) and/or **L2**
(nested Ubuntu VMs).

## Scripts

| Script                           | Runs on  | Purpose                                                                      |
| -------------------------------- | -------- | --------------------------------------------------------------------------- |
| `Create-L1Vm-Windows.ps1`        | L0 host  | Create + auto-configure the **L1** Windows Server VM (Hyper-V, Containers, VFP). |
| `Delete-L1Vm-Windows.ps1`        | L0 host  | Delete an **L1** VM from Hyper-V and remove its disk dir under `C:\VHDs`.    |
| `Install-ContainerdHnsVfp.ps1`   | L1 guest | Bring up **containerd + HNS + VFP** inside L1 (l2bridge / overlay / nat).    |
| `New-VfpPod.ps1`                 | L1 guest | Create a container **pod** on the HNS network.                              |
| `Remove-VfpPod.ps1`              | L1 guest | Remove a pod (or all pods) and optionally prune HNS endpoints.             |
| `Exec-Pod.ps1`                   | L1 guest | Exec a shell/command inside a pod.                                          |
| `Test-PodNet.ps1`                | L1 guest | Diagnose pod-to-pod / gateway connectivity (VFP dump + verdict).           |
| `Enable-VfpPortConnectivity.ps1` | L1 guest | Unblock a VFP port + install a permissive connectivity ACL (fixes fail-closed ports). |
| `Create-L2Vm-Linux.ps1`          | L1 guest | Create nested **L2** Ubuntu VMs.                                            |
| `Delete-L2Vm-Linux.ps1`          | L1 guest | Delete an **L2** VM, remove its dir under `C:\L2VMs`, free its IP ledger entry. |

Each script has a matching `.md` with full details.

## Typical flow

1. **L0 host:** `Create-L1Vm-Windows.ps1` → brings up L1 with Hyper-V + VFP.
2. **L1 guest:** `C:\scripts\Install-ContainerdHnsVfp.ps1` → containerd + HNS + VFP.
3. **L1 guest:** `New-VfpPod.ps1` → create pods; `Test-PodNet.ps1` → verify connectivity.
4. **L1 guest (optional):** `Create-L2Vm-Linux.ps1` → nested L2 Ubuntu VMs.
5. **Teardown:** `Delete-L2Vm-Linux.ps1` (L1) and `Delete-L1Vm-Windows.ps1` (L0).

---

## Command reference

### 1. L0 host — create the L1 VM

```powershell
# Create L1 from a base VHDX (differencing disk goes under C:\VHDs\<name>)
.\Create-L1Vm-Windows.ps1 -VHDXPath "C:\VHDs\my-image.vhdx" -L1VMName "L1-GeCur-2025"

# Create L1 and also install containerd + HNS + VFP inside the guest
.\Create-L1Vm-Windows.ps1 -VHDXPath "C:\VHDs\my-image.vhdx" -InstallContainerd

# Choose the in-guest network mode / isolation when auto-installing
.\Create-L1Vm-Windows.ps1 -VHDXPath "C:\VHDs\my-image.vhdx" -InstallContainerd `
    -NetworkMode l2bridge -ContainerIsolation hyperv
```

### 2. L1 guest — containerd + HNS + VFP

```powershell
# Default l2bridge, hyper-v isolated
C:\scripts\Install-ContainerdHnsVfp.ps1 -NetworkMode l2bridge

# Other modes
C:\scripts\Install-ContainerdHnsVfp.ps1 -NetworkMode overlay
C:\scripts\Install-ContainerdHnsVfp.ps1 -NetworkMode nat

# Process isolation + pin a specific uplink adapter
C:\scripts\Install-ContainerdHnsVfp.ps1 -NetworkMode l2bridge -ContainerIsolation process `
    -AdapterName "Ethernet"

# Pin component versions / run post-install validation
C:\scripts\Install-ContainerdHnsVfp.ps1 -ContainerdVersion 1.7.13 -CniVersion 1.0.0
C:\scripts\Install-ContainerdHnsVfp.ps1 -RunValidation
```

Switching `-NetworkMode` rebuilds the `cbr0` HNS network when the existing type
differs. Any existing pods must be recreated afterwards (`Remove-VfpPod` + `New-VfpPod`).

> **Re-running after a script upgrade.** For `l2bridge`, the installer sets the
> network-level host route/forwarding once (`Set-L2BridgePaRouteDelivery`). After
> pulling newer scripts onto an already-running L1, just re-run the installer to
> (re)apply it — it's idempotent. If you skip it, the next `New-VfpPod` re-adds
> the route via its idempotent fallback and prints a yellow hint.

### 3. L1 guest — pods

```powershell
# Create pods (positional name)
.\New-VfpPod.ps1 sender
.\New-VfpPod.ps1 listener

# Variants
.\New-VfpPod.ps1 sender -Image mcr.microsoft.com/windows/servercore:ltsc2022
.\New-VfpPod.ps1 sender -ProcessIsolation      # process-isolated (image build must match host)
.\New-VfpPod.ps1 sender -SandboxOnly           # sandbox only (not exec-able)
.\New-VfpPod.ps1 sender -Cleanup               # create, verify, then remove
.\New-VfpPod.ps1 sender -Namespace demo -NetworkName cbr0   # override namespace / HNS network
.\New-VfpPod.ps1 sender -Command 'ping','-t','10.244.0.34'  # override container entrypoint

# Exec into a pod
.\Exec-Pod.ps1 sender                                  # interactive cmd
.\Exec-Pod.ps1 sender -Shell powershell                # interactive powershell
.\Exec-Pod.ps1 sender ipconfig /all                    # passthrough command
.\Exec-Pod.ps1 sender -Command 'ping -n 4 10.244.0.1'
.\Exec-Pod.ps1 sender -Script .\probe.ps1              # run a local .ps1 inside the pod
.\Exec-Pod.ps1 sender -ContainerId <id> ipconfig       # target a specific container

# Remove pods
.\Remove-VfpPod.ps1 sender
.\Remove-VfpPod.ps1 -All                     # remove every pod sandbox
.\Remove-VfpPod.ps1 -All -PruneEndpoints     # also prune dangling HNS endpoints
```

> **l2bridge same-host pod-to-pod (no control plane).** On a standalone nested
> host there is no kube-proxy/flannel, so each l2bridge pod port's VFP
> `VNET_PA_ROUTE` layer carries a catch-all `PA_ROUTE` rule (`Type: paroute`)
> that, by design, **delegates** next-hop IP→MAC resolution to the *host* network
> compartment on the interface owning the HNS `ManagementIP`. HNS programs that
> rule, but on a real node a separate NC/host networking agent populates the host
> routes it consumes — with no such agent here, same-subnet pod traffic falls to
> the catch-all and is resolved off-box, black-holing it. The scripts close that
> gap using **host-stack config only (zero VFP rules — all VFP rules stay
> HNS-programmed):**
>
> - **`Install-ContainerdHnsVfp.ps1`** (`Set-L2BridgePaRouteDelivery`, once per
>   network): enables forwarding and adds an **on-link route** for the pod subnet
>   on the `ManagementIP` interface, so `paroute` resolves peers locally over the
>   shared vSwitch.
> - **`New-VfpPod.ps1`** (`Set-L2BridgeLocalDelivery`, per pod): adds a
>   **permanent static neighbor** (pod IP → MAC) so the *first* packet resolves
>   on-box with no ARP warm-up. It also re-ensures the on-link route as an
>   idempotent fallback if the installer wasn't re-run.
>
> Both are no-ops for `nat`/`overlay`.

### 4. L1 guest — connectivity test + fixups

```powershell
# End-to-end pod-to-pod diagnostic (capture full output, note the *> redirect)
.\Test-PodNet.ps1 *> output.log

# Point the diagnostic at specific pods (defaults are sender/listener)
.\Test-PodNet.ps1 -SenderName sender -ListenerName listener *> output.log

# Freshly-created VFP ports can come up fail-closed (Blocked: TRUE). Unblock them:
.\Enable-VfpPortConnectivity.ps1 -Port <PORT-GUID> -Execute
.\Enable-VfpPortConnectivity.ps1 -VMName <VMName> -Execute   # resolve port by VM name

# Port GUIDs:
vfpctrl /list-vmswitch-port
```

### 5. L1 guest — nested L2 Ubuntu VMs

```powershell
.\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1"
.\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -IPAddress 192.168.100.10
.\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -SubnetCidr 192.168.50.0/24
.\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -SwitchName "InternalNAT"
```

### 6. Teardown

```powershell
# L1 guest — delete an L2 VM (removes C:\L2VMs\<name> and frees its IP ledger entry)
.\Delete-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1"
.\Delete-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -Force       # skip confirmation
.\Delete-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -KeepFiles   # delete VM only, keep disk dir

# L0 host — delete the L1 VM (removes C:\VHDs\<name>; base image is left untouched)
.\Delete-L1Vm-Windows.ps1 -L1VMName "L1-GeCur-2025"
.\Delete-L1Vm-Windows.ps1 -L1VMName "L1-GeCur-2025" -Force
.\Delete-L1Vm-Windows.ps1 -L1VMName "L1-GeCur-2025" -KeepFiles
```
