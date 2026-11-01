# Remote Desktop from Linux to Windows: FreeRDP, Remmina or a thin client OS

To open a Windows desktop from a Linux computer there are three ways. They share the same engine, FreeRDP; what
changes is how much is done for you.

- [FreeRDP, Remmina or a thin client OS?](#freerdp-remmina-or-a-thin-client-os)
- [Why is Remote Desktop slow from Linux?](#why-is-remote-desktop-slow-from-linux)
- [Can I connect to Windows Home?](#can-i-connect-to-windows-home)
- [Two monitors, sound, webcam, USB](#two-monitors-sound-webcam-usb)

## FreeRDP, Remmina or a thin client OS?

| | FreeRDP (`xfreerdp`, `sdl-freerdp`) | Remmina | OpenThinRDP |
|---|---|---|---|
| What it is | the RDP client itself, from the command line | a desktop application with saved connections, on FreeRDP | a whole system that starts straight into the Windows sign-in, on FreeRDP |
| For | one Linux user who wants control | a Linux desktop that sometimes opens Windows | computers whose only job is Windows: terminals, thin clients, old PCs |
| RDP over UDP | not in the released versions (merged on 20 October 2026, see [UDP](../udp.md)) | as its FreeRDP | built in, falls back to TCP |
| RD Connection Broker, RDS, VDI | by hand, with options | partly | built in: broker, collections, Kerberos, RD Gateway |
| Locked down for users | no | no | kiosk: no desktop, no terminal |
| Many computers | set up one by one | set up one by one | one shared folder, signed updates with pilot devices and a way back |

On a Linux PC you use for other things too, **Remmina** is the simple choice. On a computer that should only open
Windows, a desktop with Remmina has to be locked down and kept up to date by hand; that is what OpenThinRDP does
for you ([the alternatives](../alternatives.md#linux-mint-ubuntu-or-debian-with-remmina)).

## Why is Remote Desktop slow from Linux?

The most common causes, in order:

1. **TCP on a line that loses packets** (Wi-Fi, VPN, a busy link). Windows' own client switches to UDP; Linux clients
   based on a released FreeRDP stay on TCP, and TCP stops at every lost packet. With UDP, on a line losing 50% of
   its packets we measured 19-21 frames per second, where TCP was down to 0.6 at 20% ([measurements](../udp.md#on-a-lossy-line)).
2. **Graphics mode**: without the GFX pipeline (`/gfx`) the screen is sent as plain bitmaps. OpenThinRDP uses it by
   default, with the progressive codec that keeps text sharp on servers without a GPU (`RDP_GFX`).
3. **The packaging**: a Flatpak or Snap of Remmina can be slower than the native package on some systems.
4. **The server**: a busy session host or VM is slow from any client; the
   [manager's health check](https://openthinrdp.github.io/hyper-v-rds-health-check.html) shows it.

## Can I connect to Windows Home?

No: Windows Home can connect to others but cannot be connected to with Remote Desktop, from any client. Windows
Pro, Enterprise, Education and Windows Server can (*Settings > System > Remote Desktop*). A Windows virtual machine
on Hyper-V, Proxmox or VMware usually runs Pro or Server and can. Upgrading Home to Pro is done from *Settings >
System > Activation*.

## Two monitors, sound, webcam, USB

With OpenThinRDP:

- **Several monitors** become one Windows desktop across all of them.
- **Sound and microphone** through the RDP audio channels; **webcams** through the RDP camera channel, seen by
  Teams, Zoom and the browser in the session.
- **USB sticks** appear in Windows as drives; signature keys and special devices are passed whole; **smart card
  readers** through the smart card channel.
- **Printers**: a network printer is used by Windows directly; a USB printer can be passed whole to Windows.

Try it from a USB stick, live, without touching the disk: [getting started](getting-started.md).
