# Frequently asked questions

## The project

### What is OpenThinRDP?

An open source operating system for thin clients that connect to Windows with Remote Desktop: RDS session hosts,
VDI collections behind an RD Connection Broker, or any Windows PC with Remote Desktop on. It is Debian 13 with a
locked-down kiosk on FreeRDP, the RDP UDP transport built in, and a Windows manager that runs the whole fleet from a
shared folder.

### Is it free?

Yes. Apache 2.0 licence, no cost per device, no subscription, no account. The ISO and the signed updates are on
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
clients such as Dell Wyse 5070, HP t630 or Fujitsu Futro S740 meet the requirements. See [hardware.md](hardware.md).

### Did it leave drivers out to be light?

No. The ISO has the complete Debian 13 kernel (Linux 6.12) with every driver, and every firmware package of Debian.
Whatever works with Debian 13, or with Ubuntu and Linux Mint of the same period, works here. It is light because it
runs no desktop.

### Does it run on Raspberry Pi or ARM?

Not yet. The Raspberry Pi 4 is in preparation ([#61](https://github.com/OpenThinRdp/openthinrdp/issues/61)).

### Does it run on old 32-bit thin clients?

No: Debian 13 no longer supports 32-bit only CPUs.

## Remote Desktop

### Does it really use RDP over UDP?

Yes. FreeRDP has no UDP transport in any release yet; OpenThinRDP ships FreeRDP with the pull request that adds it
([#13608](https://github.com/FreeRDP/FreeRDP/pull/13608)), which we test and report on. With `TRANSPORT=auto` the
session uses UDP, and TCP when UDP is blocked. On a line losing 50% of its packets it kept 19-21 frames per second,
where TCP was down to 0.6 at 20% ([udp.md](udp.md)).

### Which Windows can it connect to?

Windows RDS session hosts and VDI collections through an RD Connection Broker, or a single Windows PC or server with
Remote Desktop on (Pro, Enterprise, Server), on premises or in Azure, AWS or any cloud. Kerberos with NTLM as fallback,
RD Gateway, and its own WireGuard or OpenVPN for devices outside the office.

### Does it work with Azure Virtual Desktop or Windows 365?

Not yet: they need a Microsoft Entra ID sign-in and Microsoft's own gateway, which the kiosk does not do. An RDS
deployment or Windows virtual machines in Azure work, through an RD Gateway or a VPN
([desktops in the cloud](configuration.md#desktops-in-the-cloud)).

### Citrix or VMware/Omnissa Horizon?

No, OpenThinRDP is RDP only. For those, see [the alternatives](alternatives.md).

### Do webcams, headsets, USB keys and smart cards work?

Yes:

- Webcams through the RDP camera channel, and headsets through the RDP audio channels, so Teams, Zoom and the
  browser in the session see them.
- USB keys go to Windows as drives, or as whole devices: signature keys, tachograph keys and other special devices,
  also when plugged in during the session.
- Smart card readers through the smart card channel.

## Management

### Do I need a server to manage the devices?

No. The devices report to a shared folder (SMB) and read their settings from it; a PowerShell manager for Windows
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

### Does it boot over the network (PXE)?

Not yet. OpenThinRDP runs live from a USB stick or is installed, with an automatic installation for rollouts.
Network boot is considered for a later version.

### Does it support 802.1X?

Not yet. Wired 802.1X and WPA2/WPA3-Enterprise Wi-Fi are being added
([#60](https://github.com/OpenThinRdp/openthinrdp/issues/60)). Wi-Fi with a password (WPA2-Personal) and a
VPN work today.

### Why not just Linux Mint with Remmina?

The hardware support is the same, but Remmina has no RDP over UDP. A desktop also has to be locked down and set up
PC by PC, and its updates come without pilot devices or a way back. See
[the alternatives](alternatives.md#linux-mint-ubuntu-or-debian-with-remmina).

### How do I try it?

Write the ISO to a USB stick and start a PC from it: the live system writes nothing to the disk. Set the broker and
the domain, and sign in ([five minutes](../README.md#try-it-in-five-minutes)).
