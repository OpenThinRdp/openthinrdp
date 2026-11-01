# Frequently asked questions

## The project

### What is OpenThinRDP?

An open source operating system that turns a PC, an old laptop or a thin client into a Remote Desktop terminal, for
one Windows PC at home or a whole office on a domain: any Windows PC or VM with Remote Desktop on, RDS session hosts,
VDI collections behind an RD Connection Broker, on Hyper-V, Proxmox, VMware, Nutanix or any cloud. It is Debian 13
with a locked-down kiosk on FreeRDP and the RDP UDP transport built in.

### Can I use it at home, with one PC?

Yes: at the first start choose *Workgroup*, pick your PC from the list and sign in. The password can be remembered,
a PC that is off is woken up, Tailscale reaches it from outside, and a USB stick keeps your settings. No domain, no
server, no manager needed: [OpenThinRDP at home](guides/home.md).

### Is there a free alternative to IGEL OS or Dell ThinOS?

Yes: OpenThinRDP is free for any number of devices, with no licence, subscription or account, and open source. For
Windows Remote Desktop it does what they do (a locked-down sign-in, USB and smart cards, central management, updates
with pilot devices and a way back) and adds RDP over UDP. It does not speak Citrix or Horizon yet. Side by side:
[the alternatives](alternatives.md).

### Thin client, zero client or mini PC: what is the difference?

A **thin client** runs a small operating system whose only job is to open a remote desktop; a **zero client** has no
general operating system at all, only firmware for one protocol; a **mini PC** is a full computer. OpenThinRDP turns
either a thin client or a mini PC (or an old PC) into a thin client for Windows Remote Desktop.

### What is the OpenThinRDP Manager?

A free Windows application (Windows 10/11 and Windows Server, English and Italian, nothing to install) with two parts
in one window: a **health center for the Windows infrastructure**, also without any OpenThinRDP device (Hyper-V hosts
and failover clusters, Remote Desktop, domain controllers and DNS, SQL Server AlwaysOn, backups, Dell iDRAC and other
Redfish controllers, Proxmox, vSphere, Veeam, Citrix, certificates: what is wrong, in a sentence, and the repair after
you confirm), and **the management of an OpenThinRDP fleet** from the shared folder the devices report to. It is not a
PowerShell script that edits configuration files, as it was in its first weeks: since 1.0.0 (28 October 2026) it is a
project of its own with [its own releases](https://github.com/OpenThinRdp/openthinrdp-manager/releases), signed with
the project key, and it updates itself. One computer at home does not need it. Its page:
[openthinrdp.github.io/manager.html](https://openthinrdp.github.io/manager.html).

### Is it free?

Yes. The client is under the GPLv3 and the [Windows manager](https://github.com/OpenThinRdp/openthinrdp-manager) is free for any use (closed, with the commands it
runs on your servers readable): no cost per device, no subscription, no account. The ISO and the signed updates are on
[GitHub](https://github.com/OpenThinRdp/openthinrdp/releases/latest).

### Is it not too young to use in production?

It is young as a public project (October 2026), but not as a system. It comes from the thin client fleet of a
company, where it replaced a commercial thin client OS. It runs there every day on 14 devices at desks, tills, a
laboratory and weighing stations, and every release reaches that fleet. On top of that:

- 170+ system tests run on every commit;
- every release is installed in QEMU/KVM with Secure Boot;
- UDP was tested for hours with packet loss, cut networks and killed clients.

What is in production, what is only tested and what is missing: [status.md](status.md).

### Who maintains it?

The IT team of the company where it runs in production, in the open on GitHub. Bug reports, test reports on other
hardware and pull requests are welcome.

## Hardware

### Which hardware does it run on?

Any 64-bit x86 PC or thin client with UEFI or a legacy BIOS, 2 GB of RAM and 8 GB of storage (none to run it live
from a USB stick). Tested: Dell OptiPlex 3000 Thin Client in production, QEMU/KVM with UEFI and with BIOS. Used thin
clients such as Dell Wyse 5070, HP t630 or Fujitsu Futro S740 meet the requirements. See [hardware.md](hardware.md),
and the guides [replacing Dell ThinOS](guides/replace-dell-thinos.md) and
[turning an old PC into a thin client](guides/old-pc-thin-client.md).

### What OS can I put on a used Dell Wyse 5070, HP t630 or Fujitsu Futro S740?

OpenThinRDP: a free thin client OS for Windows Remote Desktop, installed from a USB stick. They meet the
requirements (64-bit x86, 2 GB of RAM, 8 GB of storage); the Wyse 3040 is at the minimum. Model by model and how
to install: [which OS for a used thin client](guides/used-thin-client.md).

### What can I do with a PC that cannot run Windows 11?

Turn it into a terminal for a Windows that is up to date: your newer PC at home, or a server or virtual machine at
work. The old PC gets a small system that updates itself and shows the Windows desktop; programs and data stay on
the up-to-date computer. [Windows 10 end of support](guides/windows-10-end-of-support.md).

### Did it leave drivers out to be light?

No. The ISO has the complete Debian 13 kernel (Linux 6.12) with every driver, and every firmware package of Debian.
Whatever works with Debian 13, or with Ubuntu and Linux Mint of the same period, works here. It is light because it
runs no desktop.

### Can I use a Raspberry Pi as an RDP thin client?

Experimentally. There is an SD card image for the Raspberry Pi 4, tested in emulation but not yet on a real board
([Raspberry Pi as a thin client](guides/raspberry-pi-thin-client.md), [what to check](arm.md)). The Pi 5 is not
supported yet. For an office today, a used x86 thin client is the safer choice.

### Does it run on old 32-bit thin clients?

No: Debian 13 no longer supports 32-bit only CPUs.

## Remote Desktop

### Does it really use RDP over UDP?

Yes. FreeRDP merged its UDP transport on 20 October 2026 ([#13608](https://github.com/FreeRDP/FreeRDP/pull/13608),
which we tested and reported on), but no release has it yet and it is built switched off unless asked for:
OpenThinRDP ships FreeRDP built with it on. With `TRANSPORT=auto` the
session uses UDP, and TCP when UDP is blocked. On a line losing 50% of its packets it kept 19-21 frames per second,
where TCP was down to 0.6 at 20% ([udp.md](udp.md)).

### Why is Remote Desktop slow or laggy?

Most often because the session runs over TCP on a line that loses packets: Wi-Fi, a VPN, a busy link. Windows' own
client switches to UDP; Linux clients based on a released FreeRDP do not. OpenThinRDP does, and falls back to TCP
when UDP is blocked. Other causes and how to tell them apart:
[Remote Desktop from Linux](guides/linux-rdp-client.md#why-is-remote-desktop-slow-from-linux).

### Which Windows can it connect to?

Windows RDS session hosts and VDI collections through an RD Connection Broker, or a single Windows PC or server with
Remote Desktop on (Pro, Enterprise, Server), on premises or in Azure, AWS or any cloud. Kerberos with NTLM as fallback,
RD Gateway, and its own WireGuard or OpenVPN for devices outside the office.

### Can I Remote Desktop into Windows Home?

No, from any client: Windows Home cannot be connected to with Remote Desktop. Windows Pro, Enterprise, Education
and Windows Server can, and so can most Windows virtual machines. Home can be upgraded to Pro from *Settings >
System > Activation*.

### Remmina or FreeRDP: which one?

They are the same engine: Remmina is a desktop application built on FreeRDP. On a Linux PC used for other things
too, Remmina is the simple choice. On a computer that should only open Windows, OpenThinRDP gives the same FreeRDP
with UDP, a locked-down sign-in and central management:
[FreeRDP, Remmina or a thin client OS](guides/linux-rdp-client.md).

### Can it open my Windows desktop by itself at power on?

Yes, on a computer used by one person: turn on *Remember password* in the settings, sign in once, and from then on
the desktop opens by itself at power on, with the password sealed in the TPM when the computer has one. A PC that is off is woken up first
([at home](guides/home.md#it-feels-like-a-computer-of-your-own)).

### Do I need RDS CALs or other Microsoft licences?

The same as for any Remote Desktop client: RDS CALs to connect to Remote Desktop Services session hosts, and for
Windows virtual desktops (VDI) the Windows licence that covers access to them (VDA or a per-user Windows Enterprise
subscription). OpenThinRDP adds no licence of its own. A single Windows Pro PC at home needs nothing more. Your
Microsoft reseller has the last word on your contracts.

### Does it work with two or three monitors? And printers?

Yes: several monitors become one Windows desktop across all of them (`MULTIMON`). A network printer is used by
Windows directly; a USB printer is passed whole to Windows, like the other USB devices.

### Does it work with Azure Virtual Desktop or Windows 365?

Not yet: they need a Microsoft Entra ID sign-in and Microsoft's own gateway, which the kiosk does not do. An RDS
deployment or Windows virtual machines in Azure work, through an RD Gateway or a VPN
([desktops in the cloud](configuration.md#desktops-in-the-cloud)).

### Does it work with Proxmox, VMware vSphere or Nutanix?

Yes. RDP is spoken by Windows inside the VM, so the hypervisor underneath does not matter: Proxmox VE, VMware
vSphere/ESXi, Nutanix AHV, XCP-ng, KVM or Hyper-V, each device to its own VM or to an RDS farm running there, with
RDP over UDP, USB, webcams and the whole fleet managed centrally. Linux desktops connect through xrdp. Setup in
[Proxmox and VMware](guides/proxmox-vmware-thin-client.md); and the
[manager](https://openthinrdp.github.io/manager.html) checks the health of Proxmox and vSphere too.

### Citrix or VMware/Omnissa Horizon?

Not yet: today OpenThinRDP speaks RDP, and native Proxmox sessions over SPICE and VNC come next. If Citrix or
Horizon is what keeps you from trying it, [tell us](https://github.com/OpenThinRdp/openthinrdp/issues): what users
ask for comes first. Meanwhile, [the alternatives](alternatives.md).

### Do webcams, headsets, USB keys and smart cards work?

Yes:

- Webcams through the RDP camera channel, and headsets through the RDP audio channels, so Teams, Zoom and the
  browser in the session see them.
- USB keys go to Windows as drives, or as whole devices: signature keys, tachograph keys and other special devices,
  also when plugged in during the session.
- Smart card readers through the smart card channel.

## Management

### Do I need a server to manage the devices?

No. The devices report to a shared folder (SMB) and read their settings from it; the free [OpenThinRDP Manager](https://openthinrdp.github.io/manager.html) for Windows
shows the whole fleet, changes settings for all devices or one, and opens the screen of any device in your browser.
No agent, no database, no management server ([the manager](manager.md)).

### How are updates done? Can I go back?

OpenThinRDP updates come as signed packages, from GitHub or from your folder. They install in the background and
apply when the session is over. A new version can go to a few pilot devices first, then to all. If something breaks,
the whole fleet or one device goes back to the version before, FreeRDP included. Debian security updates install by
themselves.

### Is it secure?

- Updates are signed, and can be signed again with the key of your site only.
- No desktop, no terminal, no text consoles.
- SSH with keys only, off by default.
- The device secrets are sealed in the TPM when there is one.
- The keys of the fleet are kept in a vault with an access code.

See [security.md](security.md) and [SECURITY.md](../SECURITY.md).

### Does it send anything to the project?

A few anonymous counts, at the first start and then once a week: the version, the model of the computer, its
processor and memory, a few yes/no, and how often sessions froze, dropped or failed and what crashed. Never names,
addresses, users, log text or anything typed. `ANON_STATS=off` switches it off; [privacy.md](privacy.md) lists
everything.

### Does it boot over the network (PXE)?

Not yet. OpenThinRDP runs live from a USB stick or is installed, with an automatic installation for rollouts.
Network boot is considered for a later version.

### Does it support 802.1X?

Yes, since 0.2.1: 802.1X on the cable and WPA2/WPA3-Enterprise Wi-Fi, with PEAP (a domain or machine account)
or EAP-TLS (a certificate from your CA). The RADIUS server is checked against your CA before any password is sent,
and on a switch without 802.1X the device goes on by itself. Setup with Windows NPS or FreeRADIUS:
[802.1X and Wi-Fi Enterprise](configuration.md#8021x-and-wi-fi-enterprise).

### Why not just Linux Mint with Remmina?

The hardware support is the same, but Remmina has no RDP over UDP. A desktop also has to be locked down and set up
PC by PC, and its updates come without pilot devices or a way back. See
[the alternatives](alternatives.md#linux-mint-ubuntu-or-debian-with-remmina).

### How do I try it?

Write the ISO to a USB stick and start a PC from it: the live system writes nothing to the disk. Set the broker and
the domain, and sign in ([five minutes](../README.md#try-it-in-five-minutes)).
