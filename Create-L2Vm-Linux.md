# Create-L2Vm-Linux.ps1 — nested L2 Ubuntu VM (cloud image)

Creates a nested **L2 Ubuntu Server VM** on Hyper-V **inside the L1 VM**, built
from the official Ubuntu **cloud image (qcow2)** — **not** the ISO installer.
There is no subiquity installer and no `yes` keypress: the pre-built cloud image
is converted to VHDX, booted directly, and a generated **cloud-init (NoCloud)**
seed configures it on first boot.

Run this in an **elevated** PowerShell session **inside the L1 VM** (the L1 VM
must already have the Hyper-V role, a guest vSwitch, and the VFP extension —
all provisioned by `Create-L1Vm-Windows.ps1`; see `Create-L1Vm-Windows.md`).

---

## What you get

| Item                 | Value                                                               |
| -------------------- | ------------------------------------------------------------------- |
| VM generation        | Generation 2, Secure Boot **off**                                   |
| RAM / vCPUs / disk   | 4096 MB static / 2 / grown to 40 GB                                 |
| Login user           | `ubuntu`                                                            |
| Password             | `ubuntu@123` (sudo, SSH password login enabled)                    |
| Hostname             | derived from the VM name (e.g. `l2-ubu-1`; prompt `ubuntu@l2-ubu-1`)|
| IP address           | explicit `-IPAddress`, or auto-allocated from the subnet           |
| Networking           | persistent static IP + DNS via netplan (cloud-init)                |
| Preinstalled tools   | `python3`, `net-tools` (ifconfig), `jq`, `curl`, `tcpdump`, `iproute2`, `iputils-ping`, `dnsutils`, `openssh-server` |
| MobaXterm            | an SSH **session** is added for the new VM (client installed by L1) |

---

## Prerequisites

- Runs **inside the L1 guest**, elevated. The L1 script must have already:
  created the `IntVirtSwitch` internal NAT switch, enabled the VFP extension,
  **rebooted so `vfpext` is running**, downloaded the cloud image to `C:\ISOs`,
  and installed MobaXterm under `C:\Tools\MobaXterm`.
- **qemu-img** is required to convert qcow2 → VHDX. If it is not on PATH the
  script auto-downloads a portable copy from `$QemuImgUrl` into `C:\Tools\qemu-img`.

---

## Parameters

| Parameter          | Type   | Description                                                                                              |
| ------------------ | ------ | -------------------------------------------------------------------------------------------------------- |
| `-L2VMName`        | string | **Required.** Name of the L2 VM. Also used to derive the Linux hostname.                                 |
| `-IPAddress`       | string | Optional. Static IPv4, e.g. `192.168.100.10`. If omitted, the next free host IP in `-SubnetCidr` is auto-selected (skipping network, broadcast, gateway, and any IP already recorded). |
| `-SubnetCidr`      | string | Optional. Subnet to auto-allocate from when `-IPAddress` is not given. Defaults to `192.168.100.0/24`.   |
| `-CloudImagePath`  | string | Optional. Path to the Ubuntu cloud image (`.img`, qcow2). Defaults to the copy in `C:\ISOs` (reused; downloaded only if none is found). |
| `-SwitchName`      | string | Optional. L1 guest vSwitch to attach to. Defaults to `IntVirtSwitch`. Must already exist if specified.   |

## Constants (edit at the top of the script)

| Constant                    | Default                                            | Purpose                                              |
| --------------------------- | -------------------------------------------------- | ---------------------------------------------------- |
| `$InternalSwitchName`       | `IntVirtSwitch`                                     | Internal NAT switch to auto-discover/attach.         |
| `$NatName`                  | `UbuntuNat`                                         | NetNat name for the internal subnet.                 |
| `$CloudImageUrl` / `$ImageCacheDir` | `.../ubuntu-26.04-server-cloudimg-amd64.img` / `C:\ISOs` | Cloud image source + cache dir.        |
| `$QemuImgUrl` / `$QemuImgDir` | portable qemu-img zip / `C:\Tools\qemu-img`       | qcow2→VHDX converter (auto-downloaded if missing).   |
| `$StartupRAMMB` / `$VProcCount` / `$VhdSizeGB` | `4096` / `2` / `40`               | RAM, vCPUs, grown disk size.                         |
| `$VmRoot`                   | `C:\L2VMs`                                          | Where L2 VM disks and the IP ledger live.            |
| `$DefaultSubnetCidr`        | `192.168.100.0/24`                                 | Subnet used when `-IPAddress`/`-SubnetCidr` omitted. |
| `$UsedIpsFile`              | `C:\L2VMs\used_ips.json`                            | Persisted IP ledger for auto-allocation.             |
| `$UbuntuUsername` / `$UbuntuPassword` | `ubuntu` / `ubuntu@123`                  | Guest login. `$UbuntuPwHash` is the SHA-512 crypt used by cloud-init. |
| `$PrefixLength` / `$DnsServer` | `24` / `8.8.8.8`                                | Netplan prefix + DNS.                                |
| `$ExtraPackages`            | python3, net-tools, jq, curl, tcpdump, ...         | Packages cloud-init installs on first boot.          |
| `$EnableVfpConnectivity`    | `$true`                                             | Enable + unblock the L2 VFP port and add permissive ACLs. |
| `$VfpIncludeIPv6`           | `$true`                                             | Include IPv6 in the permissive ACL rules.            |
| `$VfpLayerName` / `$VfpLayerPriority` | `CONNECTIVITY_ACL_LAYER` / `100`         | VFP layer created for the port.                      |
| `$VfpPortWaitSeconds`       | `90`                                                | How long to wait for the L2 VFP port to appear.      |
| `$AddMobaXtermSession`      | `$true`                                             | Add an SSH session for the new VM in MobaXterm.      |
| `$MobaXtermDir`             | `C:\Tools\MobaXterm`                                | Where the L1 script installed MobaXterm (located, not installed, here). |
| `$MobaXtermSshPort`         | `22`                                                | SSH port for the session.                            |
| `$LaunchMobaXterm`          | `$true`                                             | Launch MobaXterm after adding the session.           |
| `$RestartMobaXtermIfRunning`| `$true`                                             | Close + relaunch a running MobaXterm so the new session appears. |

---

## What the script does (in order)

1. **Derive the hostname** from `-L2VMName` (lowercased, `a-z0-9-` only).
2. **Resolve the IP** — explicit `-IPAddress`, or auto-allocate the next free
   host IP from `-SubnetCidr`/`$DefaultSubnetCidr`, skipping the network,
   broadcast, gateway (first host address), and any IP already listed in
   `used_ips.json`.
3. **Resolve the cloud image** — reuse an existing
   `ubuntu-*-server-cloudimg-amd64.img` in `C:\ISOs` (staged by the L1 script)
   or `Downloads`; only download from `$CloudImageUrl` if none is found (avoids
   the redundant re-download).
4. **Resolve the switch** — use `-SwitchName` (must exist) or auto-discover/create
   the internal NAT switch (`IntVirtSwitch`) for the subnet.
5. **Convert qcow2 → VHDX** with qemu-img and **resize** to 40 GB (cloud-init
   `growpart` expands the rootfs on first boot).
6. **Create the Gen-2 VM** (static RAM, 2 vCPUs) booting the VHDX directly.
7. **Build the cloud-init NoCloud seed ISO** (`CIDATA`) containing `meta-data`,
   `user-data` (user/password, `ssh_pwauth`, package list), and `network-config`
   (netplan static IP/DNS); attach it as a DVD drive.
8. **Secure Boot off**, set the hard disk as the first boot device, allow
   Enhanced Session Mode, and **start the VM**.
9. **Record the IP** in `used_ips.json` so future auto-allocations skip it.
10. **Enable L2 VFP connectivity** (when `$EnableVfpConnectivity`):
    - `Assert-VfpExtRunning` — verifies the `vfpext` service is running; if not,
      `Restart-Service -Force vfpext` (with a `Start-Service` fallback). Without
      this, `vfpctrl` fails with `Error (2)`.
    - `Enable-VfpPortConnectivity` — waits for the L2 port, then runs
      `/enable-port` → `/unblock-port` → adds a permissive ACL
      layer/group/rules (IPv4 + optional IPv6). `/enable-port` is the key step on
      a standalone host with no NC/SLB agent.
11. **Open the console** with `vmconnect`.
12. **Add a MobaXterm SSH session** for the VM (locates the L1-installed
    MobaXterm via `Find-MobaXterm`; it does **not** install or touch PATH). A
    running MobaXterm is closed first so the new session persists, then
    relaunched. The `ubuntu@123` password is embedded in the session as a best
    effort (MobaXterm may still prompt once and offer to save it).
13. **Print a summary** — VM name, username, password, IP, hostname, switch, SSH
    hint, and MobaXterm session.

---

## Examples

```powershell
# Name only: the next free IP in 192.168.100.0/24 is auto-allocated + persisted
.\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1"

# Pin a specific IP
.\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-1" -IPAddress 192.168.100.10

# Auto-allocate from a specific subnet
.\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-2" -SubnetCidr 192.168.50.0/24

# Attach to a manually-created switch instead of the default
.\Create-L2Vm-Linux.ps1 -L2VMName "L2-Ubu-3" -SwitchName "InternalNAT"
```

---

## After it boots

- Allow ~1–2 minutes for cloud-init to run on first boot.
- SSH from the L1 guest: `ssh ubuntu@<IP>` (password `ubuntu@123`), or open the
  new session in MobaXterm.
- Verify inside the L2 VM: `ip a`, `ifconfig`, `hostname`, `jq --version`.

---

## IP ledger (`used_ips.json`)

- Lives at `C:\L2VMs\used_ips.json`.
- Records `{ Name, Ip }` per VM so repeated name-only runs allocate distinct IPs.
- Delete or edit entries to free IPs for reuse.

---

## Troubleshooting

- **`vfpctrl` returns `Error (2)`** — the `vfpext` service isn't running or the
  port GUID is stale. The L1 script reboots so `vfpext` starts; this script also
  asserts it. A port's VFP GUID changes on every vNIC re-attach — re-fetch it
  from `vfpctrl /list-vmswitch-port` after any reboot.
- **Empty `/list-rule` or `/list-layer`** — the port genuinely has no policy yet;
  ensure `/enable-port` + `/unblock-port` ran and that you scoped the correct
  (current) port GUID. If a port **lost its rules** (e.g. after a vNIC re-attach
  or reboot), re-apply connectivity policy without rebuilding the VM using the
  copied helper in `C:\scripts`:

  ```powershell
  C:\scripts\Enable-VfpPortConnectivity.ps1 -VMName <L2-VM-name> -Execute
  # or by port GUID from `vfpctrl /list-vmswitch-port`:
  C:\scripts\Enable-VfpPortConnectivity.ps1 -Port <PORT-GUID> -Execute
  ```

  Omit `-Execute` to preview. See `Enable-VfpPortConnectivity.md`.
- **Cloud image "downloaded again"** — ensure the image exists in `C:\ISOs`
  (staged by the L1 script) or pass `-CloudImagePath`.
- **New MobaXterm session not visible** — a running MobaXterm overwrites its
  `MobaXterm.ini` on exit; the script closes and relaunches it. Keep
  `$RestartMobaXtermIfRunning = $true`.
- **No internet in the L2 VM** — the L1 host needs `New-NetNat` on the subnet and
  the gateway IP on the L1 vSwitch interface (both set up by the L1 script for
  `192.168.100.0/24`).

---

The authoritative, runnable script is **`Create-L2Vm-Linux.ps1`** (kept in sync
with this document).
