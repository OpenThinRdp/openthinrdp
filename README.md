<p align="center"><img src="docs/logo.png" alt="OpenThinRDP" width="480"></p>

<p align="center"><b>The open source thin client OS with RDP over UDP<br>
for Windows Remote Desktop, RDS and VDI: FreeRDP with the UDP transport that upstream does not ship yet.</b></p>

<p align="center">
<a href="https://github.com/OpenThinRdp/openthinrdp/releases/latest"><b>⬇ Download the ISO (latest release)</b></a>
&nbsp;·&nbsp; <a href="#try-it-in-five-minutes">Try it live, nothing installed</a>
&nbsp;·&nbsp; <a href="https://openthinrdp.github.io/">Website</a>
&nbsp;·&nbsp; <a href="README.it.md">Italiano</a>
</p>

<p align="center">
<img src="docs/screenshots/boot.png" alt="Boot menu: try it live or install" width="32%">
<img src="docs/screenshots/sign-in.png" alt="Sign-in form" width="32%">
<img src="docs/screenshots/settings.png" alt="Settings of the device" width="32%">
</p>

OpenThinRDP turns small PCs and old thin clients into kiosks that boot straight into a sign-in form and connect
to Windows: through an RD Connection Broker to the user's desktop or VM, or straight to a session host or to any
Windows PC with Remote Desktop turned on, **on premises or in the cloud** (Azure, AWS, any provider). They are
managed from a shared folder with a small Windows manager: status of every device, central settings, logo, signed
updates, and the screen of any device in your browser. No agent, no management server, no cloud service to depend
on, no licence per device.

> **Not openthinclient.** OpenThinRDP is a new, independent project, not affiliated with openthinclient: the names
> sound alike, nothing else is shared. openthinclient is an older project whose devices boot over the network (PXE)
> from its management server; OpenThinRDP is installed on each device or runs live from a USB stick, needs no server
> and is built around RDP with FreeRDP's UDP transport.

It grew out of a real migration away from a commercial thin client OS, on a fleet of Dell OptiPlex 3000 Thin
Clients connected to a Windows 11 VDI on Hyper-V, where the system it comes from runs every day.

> **Status: in production every day.** It runs the whole thin client fleet of the company it comes from: 14 Dell
> OptiPlex 3000 Thin Clients at desks, tills, a laboratory, weighing stations and a wall screen on Wi-Fi, on a
> Windows 11 VDI on Hyper-V behind two RD Connection Brokers, signing in with Kerberos and NTLM as fallback. The
> devices were converted in place from the system they ran before and take every release through their management
> folder (the manager checks each GitHub release and signs it again with the key of the site), installed during
> sessions and applied when the session is over. FreeRDP security releases reach OpenThinRDP [within 7 days](SECURITY.md#freerdp-security-fixes)
> (3.32.2: four hours). The ISO is tested in QEMU/KVM with Secure Boot at every release and the system tests run on
> every commit ([CI](https://github.com/OpenThinRdp/openthinrdp/actions/workflows/tests.yml)). What is in production,
> what is only tested and what does not exist yet:
> **[docs/status.md](docs/status.md)**. Try it live, then on one device, before rolling it out.

## RDP over UDP that keeps going on a bad line

It started with a faulty switch port losing 43% of the large packets: over TCP the remote desktop froze. We
reproduced that line, then raised the loss on every packet from the virtual machine step by step (Windows 11 VDI,
full-screen load changing every pixel, frame rate measured by the server):

| packets lost | over TCP | **OpenThinRDP over UDP** |
|---|---|---|
| 20% | 0.6 frames per second: the screen barely moves | not measured (19-21 fps at 50%) |
| 43% of the large packets\* (the faulty port) | 0-0.1 fps | **16-21 fps**, 7 minutes in a row |
| 50% | not measured (0.2 fps already at 30%) | **19-21 fps**, as on a clean line |
| 70% | not measured | **18-19 fps**\*\* |
| 80% | not measured | 4 fps, then the tunnel gives up |

\* The other rows lose that share of every packet; this one 43% of the large packets and 5% of the small ones.
\*\* At 70% the TCP connection RDP keeps beside the tunnel may end the session after 20 s without an
acknowledgement. One environment (Dell OptiPlex 3000 Thin Client, Windows 11 VDI on Hyper-V), loss emulated with
netem: [the method and the scripts](tests/udp-bench/README.md), to get your own numbers.

Getting there took a fix to FreeRDP's UDP transport, which we found and reported in
[#13608](https://github.com/FreeRDP/FreeRDP/pull/13608), and which is now part of it. Every step and the TCP
numbers: [docs/udp.md](docs/udp.md#on-a-lossy-line).

## Who it is for

- You publish desktops with **Windows Remote Desktop Services**: RD Connection Broker with session hosts or a
  Hyper-V VDI collection. Or there is no broker at all: each device connects to one Windows PC or server (set
  its name instead of the broker), e.g. a reception desk that works on the PC in the office. Devices outside the
  office go through the **RD Gateway** over HTTPS ([`RDP_GATEWAY`](docs/configuration.md#rd-gateway)) or their own
  **VPN**, WireGuard or OpenVPN ([`VPN`](docs/configuration.md#vpn)).
- Your desktops are **in the cloud**: an RDS deployment or Windows virtual machines in Azure, AWS, Google Cloud
  or with any provider, reached through the RD Gateway or a VPN, with UDP through a VPN
  ([details](docs/configuration.md#desktops-in-the-cloud)). Azure Virtual Desktop and Windows 365 are not supported
  yet (they need a Microsoft Entra ID sign-in).
- You have **x86-64 PCs or thin clients, new or old**: UEFI with or without Secure Boot, or a legacy BIOS, with the
  complete Debian kernel and firmware ([hardware](docs/hardware.md)), and want to keep them useful without a licence
  per device.
- You want to **try RDP over UDP** on real clients, or help bring it into FreeRDP.
- You need **screens that only show a web page**: hall TVs, dashboards, info points, production boards. The same
  system, no sign-in, the page chosen centrally ([see below](#screens-that-only-show-a-web-page)), so one image
  covers the whole fleet.

Not for you (yet): Citrix, VMware/Omnissa Horizon and other protocols (OpenThinRDP does RDP only), ARM devices
(the Raspberry Pi 4 is [in preparation](https://github.com/OpenThinRdp/openthinrdp/issues/61)), 32-bit only PCs.

## Requirements

| | Minimum |
|---|---|
| Device | any 64-bit x86 PC or thin client, **UEFI** (Secure Boot supported, not required) **or legacy BIOS**: old office PCs and used thin clients are fine |
| Drivers | the complete Debian 13 kernel and every Debian firmware package: what runs Debian 13 runs OpenThinRDP |
| Memory | 2 GB of RAM |
| Storage | 8 GB to install it (eMMC, SSD or disk); nothing to try it live from a USB stick |
| Network | cable, Wi-Fi (WPA2 personal) or a USB Ethernet adapter |
| TPM 2.0 | optional: with one, the device's secrets (management folder password, Wi-Fi key, SSH host keys) are kept encrypted in it ([security](docs/security.md)); without one it works the same |
| Windows side | an RD Connection Broker (RDS session hosts or a Hyper-V VDI collection), or any Windows PC or server that accepts Remote Desktop (Pro, Enterprise, Server), on premises or in any cloud |

Tested hardware and firmware settings: [docs/hardware.md](docs/hardware.md).

## Try it in five minutes

1. [Download `openthinrdp-<version>.iso`](https://github.com/OpenThinRdp/openthinrdp/releases/latest) and write it
   to a USB stick with any raw image writer (Rufus in DD mode, balenaEtcher, `dd`).
2. Boot the PC from the stick. The menu starts the **live system** by itself after 10 seconds: it runs from the
   stick and **never writes to the disk**.
3. With a network, when GitHub has a newer version than the ISO it asks whether to download it or to use the
   ISO's (no answer in 30 seconds: the newer one), so the ISO does not need downloading again for every release.
   Then the settings dialog opens: set the broker (or the name of a Windows PC) and the domain, save, sign in.
4. Like it? Restart and choose **Install**: it shows the disk it is going to erase and asks before writing
   anything (answer *Yes* to go on), then about three minutes. It installs on the **first internal disk**, never
   a USB disk (not even the installation stick). For rollouts, *Unattended install* skips the question.

What the device needs: [Requirements](#requirements).

## What it does

- **Remote desktop over UDP.** Windows sends the graphics (and USB, sound and camera) over UDP and adapts frame rate and quality to the line
  instead of queueing: smoother on busy servers, lossy Wi-Fi and VPNs. The image ships FreeRDP built with the UDP
  transport that is still under review upstream ([FreeRDP #13608](https://github.com/FreeRDP/FreeRDP/pull/13608)).
  Per device: `auto` (UDP, TCP when UDP is blocked), `udp` (UDP only) or `tcp`. In our 3-hour test with packet
  loss, bandwidth limits, network cuts and killed clients the session stayed on UDP the whole time
  ([results](https://github.com/FreeRDP/FreeRDP/pull/13608#issuecomment-6110587552)). See [docs/udp.md](docs/udp.md).
- **Sign-in form, then full screen remote desktop.** Boots in a few seconds with your logo, no desktop, no
  shell. Retries, fallback brokers, clear messages for "no network", "broker not reachable", "the virtual
  machine does not start", wrong password (never retried, so accounts are not locked). A virtual machine that is
  restarting or installing a Windows update gets "Waiting for Windows" (up to 20 minutes) instead of an error.
- **Reconnects by itself** after network drops, stops when the session is ended on purpose (sign out,
  disconnect, VM shut down by an administrator), and warns before taking over a session open on another device.
  A session taken over by another device shows "Session opened elsewhere" with *Resume here*.
- **USB done right for VDI.** Signature keys, tachograph keys and other special devices go to Windows as whole
  USB devices, also when plugged in during the session. **Webcams and headsets work in meetings**: the camera goes
  through the RDP camera channel and the microphone through the RDP audio channel, so Teams, Zoom and the browser
  in the session see both (a microphone passed as a USB device stays outside the remote session). Keyboards, mice,
  touch screens, hubs and network adapters stay local; smart card readers go through the smart card channel.
  Touch screens work as touch in Windows. With `USB_MODE=disks` USB sticks stay on the thin client and appear in
  Windows as drives; with `USB_MODE=auto` the thin client decides device by device: a stick as a drive, a device
  with storage and something else (an instrument, a key with its own driver) whole.
- **Managed from a shared folder (SMB) with a Windows manager**, no server: the whole fleet in one window, settings
  for all devices or one, and the **remote screen** of any device ([the manager](#the-manager-the-whole-fleet-from-one-window)).
- **Signed updates** that never interrupt a session: from GitHub releases (checked every 3 hours, installed in
  the background, applied when the session is over), or from your folder when you decide.
  **Try a version on a few devices first**, and **go back** to an earlier one when something breaks
  ([`UPDATE_TO`](docs/configuration.md#management)): FreeRDP goes back with it.
  Debian security updates install by themselves.
- **Settings dialog on the device** (optionally behind a PIN): broker or PC, network (DHCP, static, Wi-Fi),
  management folder and its account, USB mode, web button, power schedule, language. A new device names itself
  from its network card (`thinclient-1a2b3c`).
- **Diagnostics for the help desk**, no PIN needed (the ℹ button): network, can each broker or PC be reached,
  time, management folder, last events. Read only.
- **Locked down**: no desktop, no menus, no text consoles (Ctrl+Alt+F1..F12 do nothing), no password-less
  account.
- **Several monitors** become one remote desktop spanning all of them (`MULTIMON`).
- **Power schedule and Wake-on-LAN**, screen always on, monitors switched on late handled.
- **Web button**: a web app, free browsing, or a full screen kiosk page, with Chromium
  ([screens that only show a web page](#screens-that-only-show-a-web-page)).
- English and Italian interface; more languages are one file each.

<p align="center">
<img src="docs/screenshots/connecting.png" alt="Desktop start with the real steps" width="32%">
<img src="docs/screenshots/end-of-session.png" alt="End of session with a countdown" width="32%">
<img src="docs/screenshots/update.png" alt="Software update in progress" width="32%">
</p>

## The manager: the whole fleet from one window

`OpenThinRDP-Manager` is one PowerShell script for Windows 10/11 (English and Italian, nothing to install) that works
on the shared folder the devices report to. No server, no agent, no database: what you see is the files in the folder.

<p align="center">
<img src="docs/screenshots/manager-devices.png" alt="Manager: every device, its state, user and version, and its settings" width="49%">
<img src="docs/screenshots/manager-updates.png" alt="Manager, Updates page: all devices on one version, a pilot device on the newest" width="49%">
</p>

- **Every device at a glance**: state, user, version, last report, a readable summary and the event log of each.
- **Settings for all devices or one**, checked before saving, with the value in use on each device and what is
  still on its way.
- **A new version on a few devices first, then on all**: *Release from GitHub* asks *pilot devices only* or *all
  devices*; the others stay where they are until *Release to all devices*.
- **Back to an earlier version when something breaks**, for the whole fleet or one device, FreeRDP included: one
  click on the Updates page.
- **Remote screen** of any device in your browser, over SSH only, with a notice on the device.
- **Problems across the fleet** grouped from every event log; a **vault** for the SSH key and the signing key; your
  fleet on **its own signing key**; logo and background; and the manager **updates itself** from the signed releases.

**Everything it does, page by page, with the steps for a pilot group and for going back: [docs/manager.md](docs/manager.md).**

## Screens that only show a web page

The same image runs the screens that never need a Windows desktop: a TV in the hall, a dashboard in the
office, an info point, a board in production. With `WEB_BUTTON=kiosk` and `KIOSK_URL`:

- At power on the page opens **full screen in Chromium**: no sign-in, no desktop, no menus, no address bar.
- The page is set **centrally**, for every screen (`config\common.conf`), a group or a single one
  (`config\<hostname>.conf`) in the management folder. Change it and each screen picks it up within a few
  minutes and reopens the page, without a restart.
- It **reloads itself** every `KIOSK_RELOAD_MIN` minutes when nobody is touching it, so a page that went to an
  error after a network glitch comes back by itself.
- The **power schedule** switches the screens on and off (`POWER_ON_TIME`, `POWER_OFF_TIME`, `POWER_ON_DAYS`),
  on cable or Wi-Fi; status and events of every screen are in the management folder like any other device.
- Cookies and saved sign-ins stay across restarts. For dashboards behind a login, a link with an access token
  (offered by most dashboard tools) avoids signing in on the screen at all.
- Someone at the screen can still reach the sign-in form: it shows for 5 seconds before the page, and
  Ctrl+Shift+W closes the page. The settings can be locked with a PIN.

Settings: [docs/configuration.md](docs/configuration.md#web-button-and-kiosk-page).

## Why it is built this way

**Why FreeRDP is not updated automatically.** Debian security updates install by themselves, but FreeRDP is
excluded. First, the image ships its own FreeRDP build with UDP, which Debian's packages would replace with a
version without it. Second, the remote desktop client is the part users depend on: a new FreeRDP version can
change how sessions, USB devices, smart cards or the graphics behave, and on a fleet a regression stops everyone
at the same moment. So FreeRDP comes with OpenThinRDP releases, after testing on real devices, and you can still
keep it as it is on one device (`/etc/openthinrdp/freerdp-pinned`).

**Why UDP from a pull request that is not merged yet.** Over TCP, a busy server or a lossy line makes the screen
fall behind; over UDP, Windows lowers quality instead. The pull request is solid in our tests, and the only way
it gets merged is people using it and reporting. `TRANSPORT=tcp` is one setting away, and the image follows the
upstream code as it changes.

**Why a shared folder instead of a management server.** Every Windows network already has a file share and
someone who can manage permissions on it. The devices only read and write files there, so there is nothing to
install, patch or license on the server side, and the settings are plain text files you can read, diff and back
up.

**Why Debian.** Stable, security updates for years, every driver and firmware package, and a kiosk on top of it
that you can read: the whole client side is a few shell scripts in `rootfs/opt/openthinrdp`.

## How it compares

| | **OpenThinRDP** | Dell ThinOS | IGEL OS | Stratodesk NoTouch | ThinStation |
|---|---|---|---|---|---|
| Cost | free | comes with Dell thin clients | subscription per device | licence per device | free |
| Source | open (Apache 2.0) | closed | closed | closed | open |
| Runs on | x86-64 PCs and thin clients, UEFI or BIOS | Dell thin clients | many x86-64 devices | x86-64 PCs, Raspberry Pi | x86 PCs |
| Protocols | RDP only | Citrix, Omnissa/VMware, Microsoft and more | Citrix, Omnissa/VMware, Microsoft and more | many | many (you build the image) |
| Management | shared folder + Windows tool, no server | Wyse Management Suite | UMS server | NoTouch Center | configuration files on a network server |
| Updates | signed, from GitHub or your folder | vendor firmware | vendor | vendor | rebuild the image |
| Install | ISO, live or automatic installation | preinstalled | installer or preinstalled | installer | build, then PXE or USB |

If you need Citrix or Horizon, vendor support or certified hardware, the commercial systems are the right
choice. OpenThinRDP is for networks built on Windows Remote Desktop that want a free, open client that is simple
to manage, and for anyone who wants to put FreeRDP's UDP transport to work. Product names are trademarks of
their owners; the comparison reflects public information and our understanding, corrections are welcome.

## What comes next

Ideas we would like to build, roughly in this order. Tell us in an issue which ones you need, or send a pull
request:

- **Wi-Fi with 802.1X** (WPA-Enterprise) and wired 802.1X.
- **Network installation (PXE)** for many devices at once.
- **More tested hardware** and more languages (one file each).

## Build your own image

Your logo, your broker, your settings and keys built in (Linux with Docker or Podman):

```
cp -r image/site.example image/site      # then edit image/site/site.conf and build.conf, add your logo
image/build.sh
```

The result is `out/openthinrdp-<version>.iso`. See [docs/building.md](docs/building.md).

## Documentation

- [CHANGELOG.md](CHANGELOG.md): what changed in each release.
- [docs/status.md](docs/status.md): what is in production, what is only tested, what does not exist yet.
- [docs/configuration.md](docs/configuration.md): every setting.
- [docs/manager.md](docs/manager.md): the Windows manager, page by page: devices, settings, pilot devices and going back.
- [docs/management.md](docs/management.md): the management folder, central settings, SSH keys, signed updates.
- [docs/building.md](docs/building.md): building and customizing the image.
- [docs/security.md](docs/security.md): security model and known limits.
- [docs/hardware.md](docs/hardware.md): tested hardware and firmware settings.
- [docs/udp.md](docs/udp.md): the UDP transport and the FreeRDP the image ships.

## Layout

| Folder | Content |
|---|---|
| `rootfs/` | everything installed on the thin client (`/opt/openthinrdp`, udev rules, systemd units) |
| `image/` | the ISO build (live-build in a container), the FreeRDP build and the example site folder |
| `management/windows/` | the Windows manager (PowerShell, no installation) |
| `management/publish/` | building and signing update packages |
| `tests/` | tests that run in a Debian container |

## Contributing

Issues and pull requests are welcome. Please describe the hardware and the Windows side (broker, session
host version) for anything related to connections or devices. See [CONTRIBUTING.md](CONTRIBUTING.md) and the
[code of conduct](CODE_OF_CONDUCT.md).

Security problems: please report them privately, see [SECURITY.md](SECURITY.md).

## License

Apache License 2.0, see [LICENSE](LICENSE). OpenThinRDP uses FreeRDP (Apache 2.0), the noVNC viewer for the remote
screen (included unmodified, MPL 2.0 and BSD, [rootfs/opt/openthinrdp/novnc](rootfs/opt/openthinrdp/novnc)) and Debian packages under
their own licenses. Windows and Remote Desktop are trademarks of Microsoft; this project is not affiliated with
Microsoft or with any vendor named above.
