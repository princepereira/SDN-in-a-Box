# Install-ContainerdHnsVfp.ps1 — containerd + HNS + VFP on the L1 host

Brings up a **containerd** runtime with **HNS** networking on a **VFP**-programmed
vSwitch, **inside the L1 Windows Server VM** created by `Create-L1Vm-Windows.ps1`.

Run it **after** the L1 guest is up and its Hyper-V / Containers roles and the
**VFP switch extension** are installed (all done by `Create-L1Vm-Windows.ps1`).

> Lab/test automation. Downloads binaries from the public internet (the L1 guest
> already has outbound internet via its NAT). Not for production images.

---

## Where it runs

**Directly inside the L1 guest**, in an **elevated** PowerShell session. Copy the
script in (or add it to `$HostFilesToCopy` in `Create-L1Vm-Windows.ps1` so it lands
in `C:\scripts`), then:

```powershell
C:\scripts\Install-ContainerdHnsVfp.ps1                      # l2bridge (default)
C:\scripts\Install-ContainerdHnsVfp.ps1 -NetworkMode overlay # VXLAN overlay
C:\scripts\Install-ContainerdHnsVfp.ps1 -RunValidation       # + crictl pod test
```

---

## Parameters

| Parameter            | Default    | Description                                                                 |
| -------------------- | ---------- | --------------------------------------------------------------------------- |
| `-NetworkMode`       | `l2bridge` | HNS network type: `l2bridge` (sdnbridge), `overlay` (sdnoverlay), or `nat`. |
| `-AdapterName`       | *(auto)*   | Host adapter the `l2bridge` network binds to. Empty = fastest **Up** NIC.   |
| `-ContainerdVersion` | `1.7.27`   | containerd release (Windows amd64) to download and install.                 |
| `-CniVersion`        | `0.3.3`    | `microsoft/windows-container-networking` CNI release.                       |
| `-RunValidation`     | *(off)*    | Install `crictl` and run a pod-sandbox test (CNI → HNS endpoint → VFP).     |

## Constants (edit at the top of the script)

| Constant                                | Default                                              | Purpose                                             |
| --------------------------------------- | ---------------------------------------------------- | --------------------------------------------------- |
| `$ContainerdRoot`                       | `C:\Program Files\containerd`                         | Install root; holds `bin`, `cni\bin`, `cni\conf`.   |
| `$CniNetworkName`                       | `cbr0`                                                | Name of **both** the HNS network and CNI `name`.    |
| `$NetworkSubnet` / `$NetworkGateway`    | `10.244.0.0/24` / `10.244.0.1`                       | Container subnet + gateway.                         |
| `$OverlayVSID`                          | `4096`                                               | VXLAN VSID (overlay mode only; must be ≥ 4096).     |
| `$DnsServers`                           | `8.8.8.8`, `8.8.4.4`                                 | DNS servers handed to endpoints.                    |
| `$VfpExtensionName`                     | `Microsoft Azure VFP Switch Extension`               | Extension enabled on the HNS vSwitch.               |
| `$BaseImage`                            | `mcr.microsoft.com/windows/nanoserver:ltsc2022`      | Base image pulled with `ctr`.                       |
| `$PauseImage`                           | `mcr.microsoft.com/oss/kubernetes/pause:3.9`         | Windows pause/sandbox image for CRI.                |

---

## What the script does (in order)

1. **Prerequisites** — elevated session, `Containers` feature installed, `hns`
   service running, and at least one VFP-enabled vSwitch (warns + continues if
   none yet, since VFP is enabled on the HNS switch below).
2. **Install containerd** — download `containerd-<ver>-windows-amd64.tar.gz`,
   extract to `$ContainerdRoot`, add `bin` to PATH.
3. **Install CNI plugins** — download the Microsoft Windows CNI zip and extract
   `sdnbridge.exe` / `sdnoverlay.exe` / `nat.exe` into `cni\bin`.
4. **Load `hns.psm1`** — the `microsoft/SDN` HNS helper module.
5. **Create the HNS network** (`l2bridge` / `overlay` / `nat`) on a VFP-enabled
   vSwitch, then **enable + verify the VFP switch extension** on the switch HNS
   created and print `vfpctrl /list-vmswitch-port` (so the datapath is VFP).
6. **Write the CNI conflist** (`cni\conf\0-<name>.conflist`) targeting that
   network, with OutBoundNAT + host-route endpoint policies.
7. **Generate `config.toml`** from `containerd config default`, patched to point
   CRI's CNI `bin_dir`/`conf_dir` at `cni\bin`/`cni\conf` and set the Windows
   `sandbox_image`.
8. **Register + start** the `containerd` Windows service (auto start).
9. **Pull images** — pause + base image from MCR with `ctr`.
10. **(Optional, `-RunValidation`)** install `crictl`, point it at containerd,
    create a **Hyper-V-isolated** pod sandbox, list the resulting HNS endpoints,
    then tear it down.

---

## Build match & isolation (important)

**Process isolation requires the container base-image build to match the host OS
build.** The L1 guest is an insider / `iof_nf` build, for which **no MCR
`nanoserver` tag matches**, so:

- the `-RunValidation` pod sandbox uses **Hyper-V isolation**
  (`--runtime runhcs-wcow-hypervisor`), which is cross-build safe; and
- for **process-isolated** containers, either set `$BaseImage` to a tag matching
  your host, or import the **local** base-OS layer that ships in RitpBins
  (`hcsintegration\image\CBaseOs_*_NanoServer_*.tar.gz` with
  `hcsintegration\tools\expandlayer.exe`) — copy that folder into the guest first.

---

## Verify

```powershell
& 'C:\Program Files\containerd\bin\ctr.exe' version
& 'C:\Program Files\containerd\bin\ctr.exe' -n k8s.io images ls
Get-Service containerd | Select-Object Name, Status, StartType
Get-HnsNetwork | Select-Object Name, Type, Subnets
Get-VMSwitchExtension -VMSwitchName <switch> | Select-Object Name, Enabled   # VFP must be Enabled
vfpctrl /list-vmswitch-port                                                   # Error (2) => reboot (vfpext not started)
```

With `-RunValidation`:

```powershell
C:\Tools\bin\crictl.exe pods
C:\Tools\bin\crictl.exe images
```

---

## Notes

- **VFP:** HNS creates its own vSwitch for `l2bridge`/`overlay`; the script
  enables the VFP extension on it so container ports are programmed by VFP. If
  `vfpctrl` returns `Error (2)`, the `vfpext` driver has not started — reboot the
  L1 guest (the same requirement called out in `Create-L1Vm-Windows.md`).
- **nat mode** ignores `-AdapterName` and omits the CNI `master` field.
- Downloaded versions are pinned via `-ContainerdVersion` / `-CniVersion`; URLs
  follow the official GitHub release naming.
- The authoritative, runnable script is **`Install-ContainerdHnsVfp.ps1`** (kept
  in sync with this document).
