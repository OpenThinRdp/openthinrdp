# What OpenThinRDP does, in detail

The [README](../README.md) is the short version; this page has every feature of the thin client, the measurements
of RDP over UDP, the screens that only show a web page and why it is built this way. The Windows manager has its own
page: [manager.md](manager.md).

- [RDP over UDP that keeps going on a bad line](#rdp-over-udp-that-keeps-going-on-a-bad-line)
- [Every feature](#every-feature)
- [Screens that only show a web page](#screens-that-only-show-a-web-page)
- [Why it is built this way](#why-it-is-built-this-way)

## RDP over UDP that keeps going on a bad line

Over TCP, every lost packet stops the screen until it is sent again: a lossy Wi-Fi, a VPN or a faulty cable is
enough to freeze the remote desktop. Over UDP, Windows drops what is late and lowers the quality instead, and the
desktop keeps moving. Measured on a Windows 11 VDI with a full-screen load changing every pixel, frame rate counted
by the server, loss applied to every packet from the virtual machine:

| packets lost | over TCP | **OpenThinRDP over UDP** |
|---|---|---|
| 0% | | **15-21 fps** |
| 5% | 7-12 fps | |
| 10% | 6 fps | |
| 20% | 0.6 fps: the screen barely moves | |
| 30% | 0.2 fps: frozen | |
| 50% | | **19-21 fps**, as on a clean line |
| 60% | | **14-21 fps** |
| 70% | | **18-19 fps** |
| 80% | | 4 fps, then the tunnel gives up |

Empty cells were not measured: TCP was already frozen at 30%, and UDP at 50% ran as on a clean line. One
environment (Dell OptiPlex 3000 Thin Client, Windows 11 VDI on Hyper-V), loss emulated with netem:
[the method and the scripts](../tests/udp-bench/README.md) to get your own numbers, and every step in
[docs/udp.md](udp.md#on-a-lossy-line).

The UDP transport comes from our work in FreeRDP: we found and fixed what made it fail on lossy lines, and it was
merged upstream as [#13608](https://github.com/FreeRDP/FreeRDP/pull/13608). Upstream ships it switched off;
OpenThinRDP has it on, with `TRANSPORT=tcp` one setting away.

## Every feature

- **Remote desktop over UDP.** Windows sends the graphics (and USB, sound and camera) over UDP and adapts frame rate and quality to the line
  instead of queueing: smoother on busy servers, lossy Wi-Fi and VPNs. The image ships FreeRDP with the UDP
  transport switched on ([FreeRDP #13608](https://github.com/FreeRDP/FreeRDP/pull/13608), merged upstream, off there by default).
  Per device: `auto` (UDP, TCP when UDP is blocked), `udp` (UDP only) or `tcp`. In our 3-hour test with packet
  loss, bandwidth limits, network cuts and killed clients the session stayed on UDP the whole time
  ([results](https://github.com/FreeRDP/FreeRDP/pull/13608#issuecomment-6110587552)). See [docs/udp.md](udp.md).
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
  for all devices or one, and the **remote screen** of any device ([the manager](manager.md)).
- **Signed updates** that never interrupt a session: from GitHub releases (checked every 3 hours, installed in
  the background, applied when the session is over), or from your folder when you decide.
  **Try a version on a few devices first**, and **go back** to an earlier one when something breaks
  ([`UPDATE_TO`](configuration.md#management)): FreeRDP goes back with it.
  Debian security updates install by themselves.
- **Settings dialog on the device** (optionally behind a PIN): broker or PC, network (DHCP, static, Wi-Fi),
  management folder and its account, USB mode, web button, power schedule, language. A new device names itself
  from its network card (`thinclient-1a2b3c`).
- **Hardware test**: started by itself on the live system and from Diagnostics on any device, it checks processor,
  memory, disk, graphics driver, missing firmware, network, sound, USB, TPM, Secure Boot and the remote desktop, and
  can open a ready-made hardware report on GitHub (no name, address or serial number in it).
- **Diagnostics for the help desk**, no PIN needed (the ℹ button): network, can each broker or PC be reached,
  time, management folder, last events. Read only.
- **Locked down**: no desktop, no menus, no text consoles (Ctrl+Alt+F1..F12 do nothing), no password-less
  account.
- **Several monitors** become one remote desktop spanning all of them (`MULTIMON`).
- **4K and other large screens**: a resolution of your choice and a scale (125-200%, automatic on 4K) for the screens of the device, the web page and Windows itself (`DISPLAY_RESOLUTION`, `DISPLAY_SCALE`).
- **Power schedule and Wake-on-LAN**, screen always on, monitors switched on late handled.
- **Web button**: a web app, free browsing, or a full screen kiosk page, in the browser you choose (installed only when a web page is turned on)
  ([screens that only show a web page](#screens-that-only-show-a-web-page)).
- English, Italian and Dutch interface; more languages are one file each.

<p align="center">
<img src="screenshots/connecting.png" alt="Desktop start with the real steps" width="32%">
<img src="screenshots/end-of-session.png" alt="End of session with a countdown" width="32%">
<img src="screenshots/update.png" alt="Software update in progress" width="32%">
</p>

## Screens that only show a web page

The same image runs the screens that never need a Windows desktop: a TV in the hall, a dashboard in the
office, an info point, a board in production. With `WEB_BUTTON=kiosk` and `KIOSK_URL`:

- At power on the page opens **full screen in the browser**: no sign-in, no desktop, no menus, no address bar.
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

Settings: [docs/configuration.md](configuration.md#web-button-and-kiosk-page).

## Why it is built this way

**Why FreeRDP is not updated automatically.** Debian security updates install by themselves, but FreeRDP is
excluded. First, the image ships its own FreeRDP build with UDP, which Debian's packages would replace with a
version without it. Second, the remote desktop client is the part users depend on: a new FreeRDP version can
change how sessions, USB devices, smart cards or the graphics behave, and on a fleet a regression stops everyone
at the same moment. So FreeRDP comes with OpenThinRDP releases, after testing on real devices, and you can still
keep it as it is on one device (`/etc/openthinrdp/freerdp-pinned`).

**Why UDP on by default.** Over TCP, a busy server or a lossy line makes the screen fall behind; over UDP, Windows
lowers quality instead. The transport is now part of FreeRDP ([#13608](https://github.com/FreeRDP/FreeRDP/pull/13608),
merged after weeks of tests on our fleet), switched off there by default; OpenThinRDP switches it on, and
`TRANSPORT=tcp` is one setting away.

**Why a shared folder instead of a management server.** Every Windows network already has a file share and
someone who can manage permissions on it. The devices only read and write files there, so there is nothing to
install, patch or license on the server side, and the settings are plain text files you can read, diff and back
up.

**Why Debian.** Stable, security updates for years, every driver and firmware package, and a kiosk on top of it
that you can read: the whole client side is a few shell scripts in `rootfs/opt/openthinrdp`.

