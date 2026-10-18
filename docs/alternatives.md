# OpenThinRDP and the alternatives

What OpenThinRDP does differently from the other ways of turning PCs into Remote Desktop clients, and when another
choice is better. The facts about other products are public information as we understand it; corrections are
welcome in the [discussions](https://github.com/OpenThinRdp/openthinrdp/discussions).

- [Linux Mint, Ubuntu or Debian with Remmina](#linux-mint-ubuntu-or-debian-with-remmina)
- [IGEL OS](#igel-os)
- [Dell ThinOS](#dell-thinos)
- [Stratodesk NoTouch](#stratodesk-notouch)
- [ThinStation](#thinstation)
- [openthinclient](#openthinclient)
- [What only OpenThinRDP does](#what-only-openthinrdp-does)

## Linux Mint, Ubuntu or Debian with Remmina

A general desktop with Remmina, or with FreeRDP itself, is the usual free answer. It is a good one for a PC or two.
For a fleet of Remote Desktop clients, here is what it means.

**Hardware support is the same.** OpenThinRDP is Debian 13 with its complete kernel and every firmware package
([hardware](hardware.md#drivers-all-of-debians)). A device that works with Mint or Ubuntu of the same period works
with OpenThinRDP too. Neither side has a driver advantage.

**No RDP over UDP.** Remmina and the `xfreerdp` of the distributions use the distribution's FreeRDP. FreeRDP has no
UDP transport in any release yet: it is the pull request [#13608](https://github.com/FreeRDP/FreeRDP/pull/13608),
which OpenThinRDP builds and ships. So on a busy server, on Wi-Fi or through a VPN the session runs over TCP. On a
line that loses packets, TCP queues the screen while UDP keeps it moving ([the numbers](udp.md#on-a-lossy-line)).

**A desktop to lock down.** Users can open other programs, change the settings, fill the disk. Making it a kiosk is
your work: automatic sign-in, no terminal, no other applications, no text consoles, a session that comes back by
itself, a device that switches off when the session ends. OpenThinRDP is all of that out of the box.

**Each PC set up by hand.** There is nothing to see the state of the fleet, nothing that sets all devices or one
from one place, and no screen of a device from your desk. The [manager](manager.md) of OpenThinRDP does this from a
shared folder.

**Updates of a whole desktop.** The whole operating system updates, FreeRDP included, whenever the distribution
says so. OpenThinRDP updates come as one signed package that you can send to a few pilot devices first. If something
breaks you go back to the version before, for the whole fleet in one click. FreeRDP never changes behind your back
(Debian security updates still install by themselves).

**The details of a thin client**, which you would have to rebuild:
- the RD Connection Broker with its collection, fallback brokers, and Kerberos behind a shared broker name;
- reconnecting after a network drop, but not after a deliberate sign out;
- *Waiting for Windows* while the virtual machine restarts;
- which USB devices go to Windows whole and which as drives;
- webcams and headsets through the RDP channels, so that Teams sees them;
- smart card readers;
- a power schedule and Wake-on-LAN.

**When Mint is the better choice:** the user also needs local programs (a real desktop with a remote session now and
then), or there are one or two PCs and nobody to manage them.

## IGEL OS

A commercial thin client operating system with a subscription per device, managed by the IGEL UMS server. It runs on
many x86-64 devices, with certified hardware and vendor support, and connects with many protocols: Citrix, Omnissa
(VMware) Horizon, Microsoft AVD, Windows 365 and RDP.

**Better for:** Citrix or Horizon, Azure Virtual Desktop and Windows 365, support contracts. **OpenThinRDP is for:**
networks built on Windows Remote Desktop that do not want a cost per device or a management server.

## Dell ThinOS

The operating system of Dell (Wyse) thin clients, managed with Wyse Management Suite, with Citrix, Omnissa Horizon and
Microsoft clients. It runs only on Dell thin clients. OpenThinRDP runs on those same devices too: the production
fleet it comes from is Dell OptiPlex 3000 Thin Clients that ran ThinOS before. It also runs on any other PC.

**Better for:** a Dell-only fleet with Citrix or Horizon, under Dell support.

## Stratodesk NoTouch

A commercial thin client operating system with a licence per device, managed by NoTouch Center. It runs on x86-64
PCs and on Raspberry Pi, with many protocols. **Better for:** many protocols, Raspberry Pi today (OpenThinRDP's
Raspberry Pi support is [in preparation](https://github.com/OpenThinRdp/openthinrdp/issues/61)), vendor support.

## ThinStation

An open source, long-standing thin client toolkit. You build your own image with the protocols you need, and the
devices boot it over the network (PXE) or from a USB stick or disk; the settings are files on a network server.
**Better for:** network boot (OpenThinRDP has no PXE yet), protocols other than RDP, and very old or very small
devices. **OpenThinRDP gives you:**
- a ready image, installed or live;
- the RDP UDP transport;
- signed updates with pilot devices and going back;
- a Windows manager with the remote screen;
- the device secrets in the TPM.

## openthinclient

An open source thin client system (with a commercial offer) whose devices boot over the network from the
openthinclient server, managed from that server, with many protocols. OpenThinRDP is a different, unrelated project:
it is installed on each device or runs live, and needs no server. **Better for:** network boot from a central server,
protocols other than RDP.

## What only OpenThinRDP does

- **RDP over UDP with FreeRDP**, tested on lossy lines and in daily production
  ([udp.md](udp.md)). Over TCP a line losing 20% of its packets gave 0.6 frames per second; OpenThinRDP over UDP gave
  19-21 at 50%.
- **No server to manage the fleet:** a shared folder and a Windows manager. Settings for all devices or one, the
  remote screen over SSH, and the problems of every device read together.
- **Signed updates with pilot devices and going back**, from GitHub or from your folder, re-signed with your own key
  if you want.
- **Built from a fleet in production.** It runs every day on 14 thin clients at desks, tills, a laboratory and
  weighing stations ([status](status.md)), a fleet that left a commercial thin client OS for it.
- **Free and open** (Apache 2.0), with no cost per device.
