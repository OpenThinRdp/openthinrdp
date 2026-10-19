# Changelog

Every release, newest first. **Security** marks what every device should get at once.
Downloads and signed update packages: [releases](https://github.com/OpenThinRdp/openthinrdp/releases).

## Unreleased

- **Manager: the Windows side of the desktops** ([#74](https://github.com/OpenThinRdp/openthinrdp/issues/74)).
  For Remote Desktop Services with Hyper-V; details in [docs/manager.md](docs/manager.md#desktops-brokers-and-hyper-v-hosts).
  - A **Desktops** page: each user with the device, the personal desktop, its Hyper-V host, the state of the VM, the
    Windows session (active, idle, disconnected) and the last sign-in (which broker, ok or failed, second try). Who
    cannot sign in now is on top. Read in the background every 2 minutes.
  - **Brokers and hosts** at the top of Problems: sign-ins ok and failed per broker, a broker that fails every request
    (with its known signature, event 4648 of `tssdis.exe` without the `$`), stuck services, the self-repair task, the
    shared name answering on every address; on each host the brokers in the three local groups (through groups too),
    a stuck RDVH agent or vmms, the broker the agent is attached to, VMs with a vTPM the cluster would save. Each
    problem in one sentence, with a Fix button when a safe fix exists.
  - Actions, each confirmed with what happens and to whom, and logged in `config\changes.log`: restart the broker
    services (only while another broker is healthy, never two at once), purge its tickets, repair the host
    permissions, install the broker self-repair (`management/windows/rds`), unblock the RDVH agent; start, restart
    and shut down a VM (never saved); log off, disconnect, message, shadow; assign a personal desktop.
  - No rights on the servers: one sentence, and the rest of the manager as before.
  - Tests of the manager in Windows PowerShell 5.1 in CI, from recorded data (`tests/windows`).
- **Raspberry Pi 4 (arm64), experimental** ([#61](https://github.com/OpenThinRdp/openthinrdp/issues/61)).
  - `image/build-rpi.sh` makes an SD card image: Debian 13 arm64 with Debian's kernel and `raspi-firmware`, the same
    kiosk, and a first boot that grows the root to the card. There is no installer.
  - The FreeRDP with the UDP transport is built for arm64 too (`ARCH=arm64 image/freerdp/build-debs.sh`).
  - Update packages carry FreeRDP per architecture (`debs/amd64/`, `debs/arm64/`), and a device installs only its own.
  - Tested in QEMU (arm64 `virt`): it boots with no failed unit and opens the settings dialog, FreeRDP has UDP, and an
    update installs. It is not yet tested on a real Pi. What to check there: [docs/arm.md](docs/arm.md).
  - A Pi 4 decodes the graphics in software; the Pi 5 needs a newer kernel layout and is not supported yet.
- **The USB disk the system runs from is never passed to Windows** (a live stick with `USB_MODE=all` or listed in
  `USB_REDIRECT`), and its port is never switched off by `usb-hold.sh`.
- **Only USB disks mounted under `/media` are unmounted when the USB settings change**, so a system booted from a
  USB disk keeps its own partitions.
- **Image build:** `ADMIN_PASSWORD_HASH` of `build.conf` reaches the image intact. Its `$` parts were expanded, and
  `otradmin` got a broken hash.

## 0.2.1 (2026-10-18)

- **802.1X on the cable, and WPA2/WPA3-Enterprise Wi-Fi** ([#60](https://github.com/OpenThinRdp/openthinrdp/issues/60)).
  Networks that open a switch port only to devices that authenticate now take OpenThinRDP.
  - `DOT1X=peap|tls` for the cable, `WIFI_SECURITY=peap|tls` for Wi-Fi, with one set of EAP settings for both:
    PEAP with a domain or machine account, or EAP-TLS with a certificate from your CA (e.g. AD CS).
  - The RADIUS server's certificate is checked against your CA and its name before any password is sent.
  - The password and the certificate's key are secrets of the device, sealed in the TPM when there is one. The
    manager sends them over SSH (**802.1X...**), never through the management folder.
  - DHCP waits for the authentication. On a switch with no 802.1X at all the device goes on after 15 s and says so.
  - A password the server refuses is not tried again for an hour, so a domain account is not locked.
  - Tested against hostapd and FreeRADIUS (cable, and Wi-Fi on virtual radios). Setup notes for Windows NPS:
    [docs/configuration.md](docs/configuration.md#8021x-and-wi-fi-enterprise).
- **PCs with a legacy BIOS** ([#62](https://github.com/OpenThinRdp/openthinrdp/issues/62)). The live system already
  started on them, but the installation stopped at the boot loader. The Debian installer tried to remove the Secure
  Boot chain the image carries, a protected package, to put in the BIOS GRUB. Now on a BIOS the EFI packages are
  removed and GRUB for BIOS goes onto the disk. The boot menu is the same on BIOS as on UEFI: our entries and the 10 s
  timeout, instead of isolinux with Debian's. Old thin clients without UEFI (Dell Wyse 5060, HP t620 and the like)
  can now be installed. Tested in QEMU with SeaBIOS: live system, confirmed installation, first start from the disk.
- **No 90-second wait at every start of a device without a TPM.** The service that opens the secrets pulled
  `tpm2.target`, which on Debian waits up to 90 s for `/dev/tpmrm0`. It no longer does. It waits for the TPM itself, at
  most 10 s, only when the firmware declares one.
- **The first start of a new device no longer stays black.** At its first start a device renames itself (from its
  MAC address). With the boot now that fast, the screen could start under the old name, and after the rename no
  program could open it, the settings dialog included. The screen now starts after the rename (at most 10 s later).
  Measured in QEMU: start to settings dialog in about 20 s with a BIOS and 9 s with UEFI, from about 2 minutes.
- **An internal SATA disk is never unmounted when the USB settings change.** With `USB_MODE=all`, a change of the
  USB rules unmounted every mounted `sd*` partition that was not on USB, `/boot/efi` included, on PCs with a SATA disk.
  Now only USB disks are considered.
- **Docs: drivers and hardware.** The ISO has the complete Debian kernel and every firmware package, and the
  documentation now says so. [docs/hardware.md](docs/hardware.md) has the requirements, the tested devices, and used
  thin clients that meet the requirements.
- **Docs: FAQ and the alternatives.**
  - [docs/faq.md](docs/faq.md) answers what people ask first: hardware, drivers, UDP, Azure, PXE, 802.1X, maturity.
  - [docs/alternatives.md](docs/alternatives.md) compares OpenThinRDP with Linux Mint + Remmina, IGEL OS, Dell
    ThinOS, Stratodesk, ThinStation and openthinclient.
- **Docs: a page of its own for the manager** ([#56](https://github.com/OpenThinRdp/openthinrdp/issues/56)):
  [docs/manager.md](docs/manager.md), and screenshots of the 0.2.0 manager.
- **The manager names the devices a pilot-only release cannot hold back**
  ([#57](https://github.com/OpenThinRdp/openthinrdp/issues/57)). Devices before 0.2.0 do not know `UPDATE_TO` and take
  the newest version in the folder anyway.

## 0.2.0 (2026-10-17)

- **Pilot devices first, and going back to an earlier version** ([#50](https://github.com/OpenThinRdp/openthinrdp/issues/50)).
  New setting `UPDATE_TO`: `latest` (the default), or a version that a device installs also when it is older than its
  own, FreeRDP included, and keeps until the setting changes. The current version in `common.conf` and `latest` on a
  few devices make a pilot group. It works from GitHub (the release `v<version>`) and from the management folder,
  where every published version now has its signed index in `updates\versions\`. In the manager, **Release from
  GitHub** asks *all devices* or *pilot devices only*; a device can be made a pilot or set to a version of its own; the
  new **Updates** page shows what the fleet is on, the pilots and the versions in the folder, with **Release to all
  devices**, **Version for all devices...** and **Version from GitHub...**. A device goes back only to 0.2.0 or later.
- **The manager updates itself** ([#51](https://github.com/OpenThinRdp/openthinrdp/issues/51)). Every release carries
  `openthinrdp-manager-<version>.zip`, named and hashed in the signed `LATEST.txt`. At start the manager checks the
  latest release in the background and shows *Manager X available*; **Update the manager** checks signature and hash,
  keeps the replaced files in `previous\`, never touches `vault.otr`, the launcher `.exe` or its `.args`, restores
  everything when something fails, and restarts. `OpenThinRDP-Manager.cmd -UpdateManager` does it without a window.
- **Desktops in the cloud** ([#52](https://github.com/OpenThinRdp/openthinrdp/issues/52)): the README and
  [docs/configuration.md](docs/configuration.md#desktops-in-the-cloud) say what works with RDS or Windows virtual
  machines in Azure, AWS or any cloud (through the RD Gateway or a VPN, UDP through a VPN), and that Azure Virtual
  Desktop and Windows 365 are not supported yet.

## 0.1.15 (2026-10-17)

- **FreeRDP `dda5414`: sessions start 5 seconds sooner, the newest UDP transport**
  ([#47](https://github.com/OpenThinRdp/openthinrdp/issues/47)). FreeRDP 3.32.2 with the UDP pull request
  [#13608](https://github.com/FreeRDP/FreeRDP/pull/13608) at its 58 commits (acknowledgements as the specification
  asks, about 40% less CPU per UDP packet, no more connections that Windows 11 ended in their first second, fixes for
  Windows Server 2016) and nine fixes of FreeRDP master. With UDP
  (`/network:auto`) Windows started every session 5 s late, because the client did not count the header of the
  bandwidth measurement: from the broker's redirect to the desktop now takes 0.13–0.21 s instead of 5.1 s. With
  `RDP_GATEWAY_USE=detect` a server reached straight keeps UDP. The microphone no longer stops and restarts when
  Windows changes only its bit rate. RD Gateway and USB fixes. See [docs/udp.md](docs/udp.md#the-freerdp-in-the-image).

## 0.1.14 (2026-10-16)

- **VPN: WireGuard and OpenVPN** ([#44](https://github.com/OpenThinRdp/openthinrdp/issues/44)). A device outside
  the office reaches the broker, the management folder and the DNS of the office through its own tunnel
  (`VPN=wireguard|openvpn`); inside WireGuard the session keeps UDP. The WireGuard key is made on the device and only
  its public key is reported (the manager copies the `[Peer]` block for the server); the OpenVPN profile and its
  password go to the device from the manager over SSH, as secrets. A password the server refuses is not retried for
  an hour, so that the account is not locked.
- **RD Gateway: `RDP_GATEWAY`** ([#42](https://github.com/OpenThinRdp/openthinrdp/issues/42)). Devices outside the
  office connect through the Remote Desktop Gateway of the deployment, over HTTPS, with the credentials of the
  session; `RDP_GATEWAY_USE=detect` reaches a server on the local network straight. Through a gateway the session
  uses TCP. The diagnostics test the gateway, the manager has both settings.

- **The manager fits every screen** ([#38](https://github.com/OpenThinRdp/openthinrdp/issues/38)). The columns of
  the lists and grids share the width (the Exception column was behind a scroll bar even on large screens), rows of
  buttons wrap instead of running out of the window, the top bar and the device actions keep only their icons when
  the room is short, the window opens at 85% of the screen and can be made as small as 860×560.
- **SSH host keys by device name.** After DHCP gave the devices new addresses, a device answering at an address
  another one had was refused (remote screen, sending the site key). The manager now keeps the host keys by device
  name in its own `known_hosts`, and says so when a device really presents a new key.
- **The OpenThinRDP icon** on the windows of the manager (title bar, taskbar) and in its top bar, and
  `build-launcher.ps1`: an `OpenThinRDP-Manager.exe` with the icon that starts the manager without a console window,
  its arguments in a `.args` file next to it.
- **Updates install missing Debian packages without the recommended ones**, as the image is built: a package
  needed by a new version never brings more than its own dependencies.

## 0.1.13 (2026-10-15)

- **A vault in the manager for the SSH key and the signing key** ([#35](https://github.com/OpenThinRdp/openthinrdp/issues/35)).
  At the first start the manager asks for an access code and keeps, encrypted with it in `vault.otr` next to the
  manager, a new SSH key for the remote screen and the key that signs the update packages. Every administrator who
  starts the same manager opens it with the same code; without the code the settings can still be edited, but no
  screen opens and nothing is signed. The remote screen offers only the key of the vault, never the keys in the
  profile of the PC. Update packages are signed in the manager (**Vault > Sign an update**, or
  `OpenThinRDP-Manager.cmd -Sign <path>\LATEST.txt`), with the same Ed25519 signature `gpg` writes; `make-update.sh`
  without `-k` builds the package and leaves `LATEST.txt` to be signed there.
- **A fleet on its own key: `UPDATE_KEY=site`** ([#35](https://github.com/OpenThinRdp/openthinrdp/issues/35)).
  Devices updating from the management folder can accept only the key of the site, which the manager creates in its
  vault and sends to the devices over SSH (`site-key.sh`). **Release from GitHub** checks the project signature in
  the manager (no gpg needed any more) and signs the release again with the site key: a stolen project key installs
  nothing on such a fleet. A device without the site key still accepts the project key, so none is left without
  updates. Each device reports its site key (`SITE_KEY`, Summary > Update signatures).
- The manager read its texts with `Import-PowerShellDataFile`, which refuses more than 500 entries: the texts are
  now read entry by entry, as constants.

## 0.1.12 (2026-10-15)

- **H.264 was on although `RDP_GFX` turns it off** ([#33](https://github.com/OpenThinRdp/openthinrdp/issues/33)).
  With UDP the kiosk passes `/network:auto`, and FreeRDP applied it after `/gfx`, turning the H.264 codecs back on:
  the server encoded the whole desktop with AVC444 and dark text on saturated colours came out smeared (labels of
  point of sale buttons on magenta and yellow). The FreeRDP build of OpenThinRDP now applies `/network` before the
  other options ([FreeRDP#13748](https://github.com/FreeRDP/FreeRDP/pull/13748)): the default
  `progressive,AVC420:off,AVC444:off` gets progressive and ClearCodec again, text pixel exact, over UDP as before.
  The update installs FreeRDP `1529245ac` (3.32.2 + the UDP transport of #13608 + this fix). A
  `RDP_EXTRA=/network:lan` set to work around it can be removed once the devices have this version.

## 0.1.11 (2026-10-15)

- **A clearer manager** ([#23](https://github.com/OpenThinRdp/openthinrdp/issues/23)). Pages on the left (Devices,
  Common settings, SSH keys, Problems), the folder actions in a bar on top. The device list has five columns (a
  coloured state, who is signed in, version, last report) and a search box; the selected device has a header with
  its address and its actions (Remote screen, Logo and background) and four tabs: Settings, Summary, Events, Full
  report. Every setting shows the value in use, where it comes from (the device itself, the common settings, this
  device) and *on its way* when a saved value has not reached the device yet; the help of the selected setting is
  shown in full under the list. **Add the key of this PC** on the SSH keys page (created when missing), so another
  administrator is ready for the remote screen in one click. A screen that shows its kiosk web page is listed as
  *kiosk*. Fixed: the Problems headline stayed empty when there were no problems.
- **Settings, PIN and diagnostics in the look of the sign-in screen** ([#28](https://github.com/OpenThinRdp/openthinrdp/issues/28)).
  The settings of the device in sections (Remote desktop, Network, Wi-Fi, USB, Web page, Power on and off,
  Management) with a hint under every field; same values, same checks. When the new screen cannot open, the earlier
  dialog opens instead: the settings must always be reachable.
- **`USB_MODE=auto`** ([#26](https://github.com/OpenThinRdp/openthinrdp/issues/26)): device by device, a device that
  is only storage (a stick, a card reader) appears in Windows as a drive, a device with storage and something else
  (an instrument, a key with its own driver) goes whole. Smart card readers with storage: the reader through the
  smart card channel, the storage as a drive. Plugged in during a session, `auto` works as `disks` for now. A device
  that does not know `auto` yet reads it as `all`.
- **Kerberos only: `RDP_AUTH=kerberos`** ([#22](https://github.com/OpenThinRdp/openthinrdp/issues/22)): the sign-in
  fails instead of falling back to NTLM, for domains that turned NTLM off and to see a broken Kerberos setup at once.
- README: OpenThinRDP is not openthinclient ([#30](https://github.com/OpenThinRdp/openthinrdp/issues/30)).

## 0.1.10 (2026-10-15)

- **Remote screen from the manager** ([#19](https://github.com/OpenThinRdp/openthinrdp/issues/19)). *Device settings >
  Remote screen...* shows the screen of a device in your browser and lets you use it: to help a user, or to sign in
  once to a dashboard on a screen with no keyboard. Over SSH only (administrators' key, one-time password, x11vnc and
  the viewer on 127.0.0.1 as the account that owns the screen), nothing to install on the PC (Windows' `ssh.exe` and
  the browser). The device shows *Remote assistance active* while it lasts and records it in its events; it ends with
  the manager's window or after 2 hours. `REMOTE_SCREEN=off` turns it off. The update installs `x11vnc` (11 MB, needs
  the Debian mirror once); the viewer, noVNC 1.7.0, is included unmodified, with a standard-library WebSocket bridge
  instead of websockify (about 50 MB of dependencies).
- README: the manager gets a section of its own, with the remote screen.
- **The device's secrets in the TPM, when there is one** ([#17](https://github.com/OpenThinRdp/openthinrdp/issues/17)).
  The management folder password, the Wi-Fi key and the SSH host keys are kept encrypted with a key that never
  leaves the TPM 2.0 and decrypted at every start into memory, before the network and SSH; a disk or eMMC taken
  out of the device gives nothing. Devices set up before move their plain files into the TPM at the next start,
  keeping the same SSH host keys. Bound to the TPM only, so BIOS updates do not lose them. Without a TPM nothing
  changes, so older PCs keep working. The status file says which mode a device is in (`SECRETS=`). The update
  installs the TPM libraries systemd needs (needs the Debian mirror once). The folder password and the Wi-Fi key
  keep their usual paths (links to memory), so the network configuration does not change; each secret is read back
  and compared before its plain file goes. `TPM_SECRETS=off` keeps a device out of the TPM or brings it back out,
  and set centrally it counts from the first start after the update: a fleet can be moved one device at a time.

## 0.1.9 (2026-10-14)

- **Started from the ISO, the latest version first** ([#12](https://github.com/OpenThinRdp/openthinrdp/issues/12)).
  A device still on the version of its image (live system, or installed and never updated) checks for updates
  before the kiosk opens and, when there is a newer version, asks *Download and use 0.1.x* or *Use 0.1.y* (no
  answer in 30 s: the newer one, so unattended installs end up current). It used to update in the background a few
  seconds after the kiosk had opened, and restart it. The ISO is no longer rebuilt for every release: a release
  is the signed update package plus the ISO already published, a new ISO only when the base system changes.
- **A USB device that hangs no longer ends the session** ([#10](https://github.com/OpenThinRdp/openthinrdp/issues/10)).
  Windows started the devices passed whole together with the display of the session; a USB stick that hung at
  start held Plug and Play for 60 s and Windows closed the session ("display driver not ready", reported to
  FreeRDP as [#13719](https://github.com/FreeRDP/FreeRDP/issues/13719)), and at the second time the kiosk took it
  for a session taken over and switched the device off. The devices passed whole now arrive 15 s after the
  desktop: their hub port is off while the session starts (`usb-hold.sh`), then on again, so for Windows they are
  plugged in with the session running and a device that hangs fails on its own. If anything goes wrong the ports
  come back on by themselves after 2 minutes.

## 0.1.8 (2026-10-14)

- **A USB network adapter works as soon as it is plugged in** ([#8](https://github.com/OpenThinRdp/openthinrdp/issues/8)).
  It used to stay without an address until the settings were saved: the udev rule matched the adapter's name
  before udev renamed it (`eth0`/`usb0`, then `enx…`), so it never matched a USB adapter; at boot an adapter
  appearing while the settings were being applied was configured by nobody; and the address request started in
  the background was killed with the udev job. Plugged in with the device running or present at boot, it now gets
  its address within seconds, without touching the adapter in use. A Wi-Fi adapter whose driver loads late is
  picked up the same way.
- **Wi-Fi survives kernel updates** ([#7](https://github.com/OpenThinRdp/openthinrdp/issues/7)). The initramfs
  built for the device included the Wi-Fi driver without the part it loads later (Intel: `iwlwifi` without
  `iwlmvm`), so after the next kernel update a device on Wi-Fi came up with no Wi-Fi adapter at all and no network.
  Only wired and graphics drivers go in now; devices set up by older versions get the Wi-Fi drivers taken out at
  the next boot (the boot after that has the adapter back).
- The DROPPED event names why FreeRDP ended the session (its last connection error), not the channels that
  fail while the connection closes behind it (it named a smart card channel after the UDP tunnel broke down).

## 0.1.7 (2026-10-13)

- **Manager: Problems tab.** The event logs of all devices read together for a period and grouped: failed sign-in
  attempts by broker, dropped sessions by cause, refused sign-ins, sessions taken over, failed updates. The same
  problem on 3 or more devices is highlighted ([management.md](docs/management.md#problems-across-the-fleet)).
- **`USB_MODE=disks` keeps USB sticks on the thin client also when they are plugged in during a session.** The
  class filter did not include storage, so FreeRDP took a stick plugged in mid-session as a whole USB device and
  Windows got a raw disk without a drive letter instead of the shared drive. Devices listed in `USB_REDIRECT` still
  go whole.
- **Waiting for Windows instead of failing.** When the broker answers but the virtual machine refuses the desktop
  (it is restarting or installing a Windows update), the device no longer spends its attempts and ends on "desktop
  not available", nor reconnects every few seconds to sessions that Windows drops after ~22 s while it finishes the
  update. It shows *Waiting for Windows* with the minutes elapsed and a Cancel button, tries again every 20 s, and
  connects as soon as the desktop is ready (up to 20 minutes). One event when the wait starts, one every 5 minutes.
- **Dropped sessions keep their log.** The FreeRDP log of a dropped session stays as `/tmp/kiosk.log.prev` (the
  reconnection starts a new one at once) and the DROPPED event ends with its last error, so the cause can be read
  afterwards, also in the manager's Problems tab.
- Updates from GitHub are checked every 3 hours instead of 6.
- The central settings are not applied while an update is installing (a valid setting could be rejected with half
  the files updated).

## 0.1.6 (2026-10-13)

- **Session taken over from another device.** Windows 11 ends the session of the device left behind with code 1, the
  same as a VM shutdown (measured directly on the VM and through the broker), never with 5. The device now checks
  whether the VM still answers: if it does, it shows "Session opened elsewhere" with Resume here, instead of the
  shutdown page that switched it off.
- **Startup progress.** The progress screen showed each step one step late (it read one line per wake-up), so it
  stayed on "Connecting to the broker" while the broker was starting the VM. Every step now shows at once, and after
  5 s on the broker it says the virtual machine is being started.
- **Kerberos behind a broker alias.** With `RDP_AUTH=negotiate` the device connects to one of the brokers behind
  a round-robin name by that broker's own name: the Kerberos ticket was otherwise asked for whichever broker the
  Kerberos library looked up, and the other one refused it. NTLM-only (`RDP_AUTH=ntlm`) is no longer needed there,
  and the device keeps two ways to sign in instead of one.
- **Manager: Check permissions.** Lists what the devices' account can change in the management folder
  besides `status\`, through which group, and what every user can change there
  ([management.md](docs/management.md#account)).
- Devices report the account of the management folder (`MGMT_ACCOUNT`, never the password).
- `SUMMARY.csv` moves into `status\`, so the devices need write access there only.

## 0.1.5 (2026-10-12)

- **The installer asks before erasing the disk.** *Install* shows the internal disk it is going to use and
  the partitions it will write, and asks ("No" preselected); old LVM volumes or software RAID on that disk are
  never removed without a question either. *Unattended install*, a separate entry of the boot menu, keeps the
  old behaviour for rollouts on known hardware.
- **FreeRDP: pull request #13608 unchanged, no patches of ours.** The author took our two fixes into the pull
  request (ten SYN attempts, and the root cause of the false "stream is stuck" on lossy lines), which also
  removes a 1 s freeze at every wrap of the channel sequence under loss: with 70% of the packets lost the
  session now keeps 18-19 frames per second instead of 9-13.
- **Settings PIN salted and stretched** (PBKDF2-SHA256, 600,000 iterations) when set from the manager; a PIN
  of 0.1.4 and earlier keeps working.
- Docs: the devices' account needs write access to `status\` only ([management.md](docs/management.md#account));
  replacing or revoking the release key through the update channel ([SECURITY.md](SECURITY.md)).
- FreeRDP gets 20 s instead of 30 to bring a connection up: a broker that accepts the connection and then hangs
  costs this much on every attempt before the next broker is tried. Still above the 15 s a broker took to prepare
  a virtual machine.
- The system tests (93) and a shell syntax check run in Debian 13 on every push and pull request
  ([CI](https://github.com/OpenThinRdp/openthinrdp/actions/workflows/tests.yml)).

## 0.1.4 (2026-10-12)

- **The project moved to the OpenThinRDP organization**: https://github.com/OpenThinRdp/openthinrdp, website
  https://openthinrdp.github.io/. The old addresses redirect, and devices already installed keep updating.

- **Security: FreeRDP 3.32.2**, the security release of 2026-10-12, with the UDP transport (pull request #13608)
  on top. The USB fixes #13674, #13679 and #13618 are part of 3.32.2.
- **UDP holds on lossy lines.** We found and fixed a bug in the UDP transport: after the channel sequence wrapped,
  a wrong elapsed time (an unsigned difference going below zero) made the client believe the stream had been stuck
  for ages, and it ended the connection within seconds whenever packets were being lost. Now the session keeps
  **20 frames per second with 50% of the packets lost and 9 with 70%**, and still draws at 80%; TCP is down to
  0.6 at 20%. The tunnel is also set up with ten attempts instead of four. Both fixes are proposed to FreeRDP in
  pull request #13608. See [docs/udp.md](docs/udp.md).
- FreeRDP gets 30 s instead of 9 to bring a connection up and to wait for the TCP connection beside the UDP
  tunnel (`/timeout`): a broker preparing a virtual machine in 15 s no longer makes the first attempt fail, and on
  a very lossy line the TCP connection is not given up while the UDP tunnel still carries the session.
- **Fix: no microphone in meetings with a webcam.** A webcam was passed to Windows as a whole USB device, and
  Windows keeps the microphone of such a device in the console session: Teams and Zoom in the remote session found
  no microphone at all. Webcams and USB headsets now stay on the thin client: the camera goes through the RDP
  camera channel ([MS-RDPECAM]), the microphone and the speaker through the RDP audio channels. Devices plugged in
  during the session follow the same rule, and a webcam an earlier version had passed over USB is given back to
  the thin client by itself (its Linux drivers are attached again).
- **Updates installed during a session take effect when it is over**: as soon as the device is back to the
  sign-in screen, or a new connection starts, the screen reloads with the new version (before: at the next start).
- The mouse pointer on the kiosk screens (sign-in, progress, messages) hides while the mouse is still and comes
  back as soon as it moves; in the remote desktop it is Windows' own pointer as before.
- Fix: a device moved to another management folder by `MGMT_SHARE` in the common settings went back to the
  folder of its image at the next report, and kept bouncing between the two.

## 0.1.3 (2026-10-12)

In production: this version runs a fleet of thin clients converted in place, updated from their management folder.

- **New screens for the user** (GTK, full screen, on the background of the site): sign-in with the clock and date,
  information and settings small in the top right corner, power with **Restart** and **Shut down** bottom right,
  the web button bottom left; desktop start with a progress bar that follows the real steps (broker, redirection,
  desktop on screen); errors, no network, session open elsewhere, session taken over, end of session with a
  countdown. Settings, diagnostics and PIN stay simple dialogs (administrators only).
- **Software updates**: a notice with the progress in the top right corner while one installs; **Shut down
  during an update** shows it full screen and switches off when it is done (before, it interrupted the install).
- The boot screen always shows the picture and colors of the image (OpenThinRDP's, or yours when you build your
  own image); the picture of the management folder is the background of the sign-in screen, which is drawn
  again as soon as a new one arrives. In the manager the button is now **Logo and background...**.
- Devices still showing the provisional logo of 0.1.0 get the current one (only exact project pictures are
  replaced, never those of your own image).
- **FreeRDP**: the USB fix for a client hanging on disconnect is now [FreeRDP#13679](https://github.com/FreeRDP/FreeRDP/pull/13679)
  (by the FreeRDP maintainer, from our #13677); [#13674](https://github.com/FreeRDP/FreeRDP/pull/13674) was approved.
- Manager: a picture whose width already fit was not scaled to the height.
- Day and month of the sign-in screen follow `LANGUAGE`, not the system locale.

## 0.1.2 (2026-10-12)

- **Fix**: update packages always carry 755/644 modes. The 0.1.1 package was built with umask 002, and a device
  that installed it got a group-writable `/etc`, so sshd refused every key. Installing 0.1.2 repairs it.
  The 0.1.1 package was withdrawn; the 0.1.1 ISO was not affected.
- The README links always point to the latest release.

## 0.1.1 (2026-10-12)

- **Security**: no text consoles. Ctrl+Alt+F1..F12 and Ctrl+Alt+Backspace do nothing in the kiosk, no spare
  consoles with a login prompt, the `kiosk` account is locked. In 0.1.0 `kiosk` had no password: anybody at the
  keyboard could get a shell with Ctrl+Alt+F2. Devices updated from 0.1.0 are fixed too.
- Secrets (Wi-Fi key, management folder password) are never printed back, only their hash.
- Logo and boot image from the Windows manager, for every device or for one (`config\branding\`); the boot
  splash follows, also when only the colors change.
- Diagnostics button (ℹ) on the sign-in form, without a PIN: network, brokers, time, management folder, events.
- A new device names itself `thinclient-` + the last 6 digits of its MAC address.
- Management folder account in the settings dialog and in the central settings (`MGMT_USER`, `MGMT_PASSWORD`).
- `MULTIMON=auto|off`: one remote desktop over every monitor.
- Certificate authorities of the site are trusted by the system too.
- Settings labels with a colon (`hh:mm`, `VID:PID`) were cut short since 0.1.0.
- README: direct connection to a Windows PC, what comes next.

## 0.1.0 (2026-10-11, pre-release)

- First public version: kiosk with FreeRDP and the UDP transport, USB for VDI, management from a shared folder
  with a Windows manager, signed updates from GitHub or the folder, ISO with a live system and automatic
  installation.
