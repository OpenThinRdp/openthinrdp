# OpenThinRDP for companies: free thin clients for Remote Desktop Services and VDI

OpenThinRDP is a thin client operating system for organisations that publish Windows desktops with Remote Desktop:
RDS session hosts, VDI collections behind an RD Connection Broker, or Windows VMs on Hyper-V, Proxmox, VMware or
any cloud. It runs on the PCs and thin clients you already own, is managed from a shared folder you already have,
and costs nothing per device.

- [What your users get](#what-your-users-get)
- [What IT gets](#what-it-gets)
- [Security](#security)
- [Coming from IGEL OS, Dell ThinOS or another thin client OS](#coming-from-igel-os-dell-thinos-or-another-thin-client-os)
- [What it costs](#what-it-costs)
- [In production, with the evidence](#in-production-with-the-evidence)
- [Rolling it out](#rolling-it-out)

## What your users get

- **Power on, sign in, work.** The device starts in seconds into a sign-in form with your logo, then the Windows
  desktop in full screen. No local desktop to get lost in.
- **Smooth on Wi-Fi, VPNs and busy lines.** RDP over UDP is built in: at 50% packet loss the desktop still runs at
  19-21 frames per second, where TCP is frozen ([the numbers](../udp.md#on-a-lossy-line)).
- **Their devices work.** USB sticks as drives; signature keys, tachograph keys and instruments passed whole, also
  when plugged in during the session; webcams and headsets in Teams and Zoom; smart cards; several monitors; touch.
- **Clear messages instead of error codes**: "Waiting for Windows" while a VM restarts, "Session opened elsewhere"
  with *Resume here*, and a session that comes back by itself after a network drop.

## What IT gets

- **Zero-touch from the domain.** A new device needs a domain account and nothing else: it finds its management
  folder in the domain by itself ([how](../manager.md#settings--manager-language-and-local-copy)).
- **No management server.** Settings, status and updates live in a shared folder (SMB). No agent, no database,
  nothing to install or license on the server side; the settings are text files you can read and back up.
- **Updates you control.** Signed packages, installed in the background and applied when the session ends. A new
  version on a few pilot devices first, then on all; back to the version before in one click, for the fleet or one
  device ([management](../management.md)).
- **A free manager for Windows** that shows every device, who cannot sign in and why, and the remote screen of any
  device; and a [Health Center](hyper-v-rds-health-check.md) for the infrastructure behind the desktops: Hyper-V and
  clusters, brokers, AD and DNS, SQL Server, backups, iDRAC, Proxmox, vSphere, Veeam, Citrix and certificates
  ([the manager](https://openthinrdp.github.io/manager.html)).
- **Help desk diagnostics** on every device without a PIN: network, brokers, time, management folder, last events.

## Security

- No desktop, no terminal, no text consoles; the settings dialog behind a PIN.
- Signed updates, with your own signing key if you want it; Debian security updates by themselves; FreeRDP security
  releases within 7 days ([SECURITY.md](../../SECURITY.md#freerdp-security-fixes)).
- Kerberos with NTLM as fallback or Kerberos only; RD Gateway; WireGuard or OpenVPN for devices outside the office.
- 802.1X on the cable and WPA2/WPA3-Enterprise Wi-Fi (PEAP or EAP-TLS with your CA).
- Device secrets sealed in the TPM when there is one; SSH with keys only, off by default.

The model and its limits: [security](../security.md).

## Coming from IGEL OS, Dell ThinOS or another thin client OS

OpenThinRDP installs on the same x86-64 hardware: Dell Wyse and OptiPlex Thin Clients, HP t-series, Fujitsu Futro,
IGEL x86-64 models, office PCs ([which ones](used-thin-client.md)). It speaks RDP: for Windows Remote Desktop it does
what they do and adds RDP over UDP; for Citrix or Omnissa Horizon, keep them for now and
[tell us](https://github.com/OpenThinRdp/openthinrdp/issues) what you need.

- From Dell ThinOS: [replacing Dell ThinOS](replace-dell-thinos.md), with the settings to copy.
- Side by side with IGEL OS, ThinOS, Stratodesk, ThinStation and openthinclient: [the alternatives](../alternatives.md).

## What it costs

Nothing per device, no subscription, no account: the thin client is open source (GPLv3), the manager free for any
use. Microsoft's licences apply as for any Remote Desktop client (RDS CALs, or VDA for Windows virtual desktops);
OpenThinRDP adds none of its own. The hardware is often what you already have.

## In production, with the evidence

OpenThinRDP runs the whole thin client fleet of the company that built it: Dell OptiPlex 3000 Thin Clients at desks,
tills, a laboratory, weighing stations and a wall screen on Wi-Fi, on a Windows 11 VDI on Hyper-V behind two RD
Connection Brokers. Every release reaches them through their management folder. Rollback, an interrupted update,
a network cut and zero-touch were tested on a device of that fleet: [production readiness](../maturity.md), and what
is still missing: [status](../status.md).

## Rolling it out

1. Try it **live** from a USB stick on one device: nothing is written to the disk.
2. Create the management folder and run the manager ([getting started](getting-started.md)).
3. Name the folder in the domain: every new device then sets itself up with a domain account.
4. Install with *Unattended install* from a stick, device by device; updates and settings arrive from the folder.
