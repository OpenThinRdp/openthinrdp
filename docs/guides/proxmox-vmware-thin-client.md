# A free thin client for Proxmox, VMware and Nutanix VMs

Your Windows desktops run on **Proxmox VE, VMware vSphere/ESXi, Nutanix AHV, XCP-ng or KVM**? OpenThinRDP connects
to them today. Remote Desktop is spoken by Windows inside the VM, so the hypervisor underneath does not matter: the
same client, the same features, the same five-minute setup as on Hyper-V.

- **RDP over UDP**: the desktop keeps moving on a lossy Wi-Fi or VPN where TCP freezes
  ([the numbers](../udp.md#on-a-lossy-line)).
- **Everything a desk needs**: USB sticks and signature keys, webcams and headsets for Teams, smart cards, serial
  instruments, several monitors.
- **Any PC becomes a thin client**: old office PCs and used thin clients, UEFI or BIOS, from 2 GB of RAM, no licence
  per device.
- **The whole fleet from one window**: central settings, signed updates with pilot devices, power on, remote screen,
  without a management server.
- **And the servers too**: the [manager](https://openthinrdp.github.io/manager.html) checks Proxmox (quorum, storage,
  backups, failing disks) and vSphere (hosts, datastores) next to your Windows side, free.

- [Three ways to connect](#three-ways-to-connect)
- [Step by step](#step-by-step)
- [Linux desktops through xrdp](#linux-desktops-through-xrdp)
- [Next: native Proxmox sessions](#next-native-proxmox-sessions)

## Three ways to connect

| You have | Set on the device | What the user gets |
|---|---|---|
| **One Windows VM per desk** (a reception desk, a till, a lab PC moved into a VM) | `BROKER` = the name of the VM | signs in and lands on that VM, full screen |
| **An RDS farm** whose session hosts are VMs on Proxmox or VMware | `BROKER` = the RD Connection Broker, `LOAD_BALANCE_INFO` = the collection | the broker sends each user to a session host |
| **A Windows PC or server** anywhere, also in a cloud | `BROKER` = its name, with the [RD Gateway](../configuration.md#rd-gateway) or a [VPN](../configuration.md#vpn) from outside | the same |

The VM needs only what Windows needs for any Remote Desktop client: Remote Desktop on (Windows Pro, Enterprise or
Server) and the users in *Remote Desktop Users*. Nothing to install on Proxmox, vCenter or in the VM.

## Step by step

1. [Download the ISO](https://github.com/OpenThinRdp/openthinrdp/releases/latest), write it to a USB stick and start
   the device from it: try it live, nothing is installed ([getting started](getting-started.md)).
2. In the settings of the device (the gear on the sign-in form): the name of the VM or the broker, the domain, the
   keyboard. Sign in: the desktop opens.
3. Install it on the device from the boot menu when you like what you see.
4. For a fleet, one file each: the management folder holds `config\common.conf` for what all devices share and
   `config\<device>.conf` with `BROKER=<its VM>` for each desk; the
   [manager](https://openthinrdp.github.io/manager.html) writes them for you
   ([management](../management.md)).

## Linux desktops through xrdp

A Linux VM with [xrdp](https://www.xrdp.org/) is a Remote Desktop server too: set its name as `BROKER` and the
device opens the Linux desktop. xrdp speaks RDP over TCP; with `TRANSPORT=auto`, the default, the device uses TCP by
itself. Running it? [Tell us how it goes](https://github.com/OpenThinRdp/openthinrdp/discussions).

## Next: native Proxmox sessions

On the roadmap: sessions over **SPICE**, Proxmox's own protocol, with the VM chosen in Proxmox itself for each user,
Linux VMs and the VM console included, and **VNC**. Want it first, or something else, such as Citrix or Horizon?
[Open an issue](https://github.com/OpenThinRdp/openthinrdp/issues): what users ask for comes first.
