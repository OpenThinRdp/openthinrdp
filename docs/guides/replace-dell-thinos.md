# Replacing Dell ThinOS with OpenThinRDP on Dell thin clients

Dell OptiPlex Thin Clients and Wyse thin clients that run ThinOS are 64-bit x86 PCs with UEFI. OpenThinRDP runs
on them like on any other PC: the production fleet OpenThinRDP comes from is Dell OptiPlex 3000 Thin Clients that ran
ThinOS before, and they connect every day to a Windows 11 VDI through two RD Connection Brokers.

This guide is for networks built on **Windows Remote Desktop** (RDS session hosts, a VDI collection, or Windows PCs).
If your users need Citrix or Omnissa Horizon, keep ThinOS: OpenThinRDP does RDP only.

- [1. Write down what ThinOS connects to](#1-write-down-what-thinos-connects-to)
- [2. Firmware settings](#2-firmware-settings)
- [3. Try it live, nothing installed](#3-try-it-live-nothing-installed)
- [4. Install](#4-install)
- [5. Many devices: the management folder](#5-many-devices-the-management-folder)
- [6. What changes for the users](#6-what-changes-for-the-users)

## 1. Write down what ThinOS connects to

From the ThinOS configuration, or from Wyse Management Suite, write down:

| ThinOS | OpenThinRDP setting |
|---|---|
| the RD Connection Broker or session host | `BROKER` (and `BROKER_FALLBACK` for a second broker) |
| the collection (VDI pool or RemoteApp/desktop collection) | `LOAD_BALANCE_INFO`, as `loadbalanceinfo` in the .rdp file, e.g. `tsv://VMResource.1.VDI` |
| the domain | `DOMAIN`, its full DNS name for Kerberos (e.g. `example.local`) |
| an RD Gateway, for devices outside the office | `RDP_GATEWAY` |
| USB devices redirected whole (signature keys, special devices) | `USB_REDIRECT` (`VID:PID` list) |

Everything else (network, time, power schedule, logo) is set the same way: [all the settings](../configuration.md).

## 2. Firmware settings

Open the firmware setup (F2 at power on on Dell devices). On devices that came with ThinOS it is often protected
by an administrator password: Dell documents a default one for its thin clients, and ThinOS or Wyse Management Suite
may have set another.

- **Enable USB boot** (Integrated Devices, or the boot configuration), to start from a stick. F12 at power on opens
  the one-time boot menu.
- **Secure Boot can stay on**: OpenThinRDP boots with Debian's signed shim and GRUB.
- **Wake-on-LAN**: enable it, and **disable Deep Sleep Control**. With deep sleep in S4/S5 the network card is off,
  the magic packet never arrives, and the alarm of the power schedule cannot switch the device on either.

Once OpenThinRDP runs, these settings can also be read and changed from Linux through `dell-wmi-sysman`, without the
setup screen ([hardware](../hardware.md#firmware-settings-dell)).

## 3. Try it live, nothing installed

1. Write the [ISO](https://github.com/OpenThinRdp/openthinrdp/releases/latest) to a USB stick (Rufus in DD mode,
   balenaEtcher or `dd`).
2. Start the thin client from the stick (F12). The live system starts by itself after 10 seconds and **never writes
   to the internal disk**: ThinOS is still there when you remove the stick.
3. In the settings dialog set the broker, the collection and the domain, save, and sign in as a user.

Check what matters to you before installing: the monitors, the USB devices your users plug in, the webcam and
headset in Teams, smart cards, sound. The diagnostics (ℹ on the sign-in screen) show the network, the brokers and the
time.

## 4. Install

Restart from the stick and choose **Install**. The installer shows the disk it is going to erase and asks; answer
*Yes* and it takes about three minutes. It installs on the **internal** disk (eMMC or SSD), never on a USB disk.

Installing **erases ThinOS**. Going back needs Dell's recovery image for that model: make sure you can get it before
you install, if you may want to go back. For many devices, the *Unattended install* entry of the boot menu skips the
question.

## 5. Many devices: the management folder

Instead of Wyse Management Suite, OpenThinRDP uses a shared folder (SMB) and a Windows tool, with no server:

1. Create the folder, e.g. `\\fileserver\thinclients`, with an account the devices use to write their status
   ([management](../management.md#account)).
2. Put the common settings in `config\common.conf` (broker, collection, domain...), and the settings of a single
   device in `config\<hostname>.conf`.
3. Set `MGMT_SHARE` on each device, or build your own image with it ([building](../building.md)).
4. Run the [manager](../manager.md): the state of every device, settings for all or one, the screen of any device,
   updates that go to a few pilot devices first, and going back to the version before when something breaks.

## 6. What changes for the users

- They see a sign-in form with your logo, type their user and password, and get their desktop in full screen. At
  the end of the session the device can switch itself off.
- Sessions use **RDP over UDP**: on Wi-Fi, a VPN or a busy server, the screen keeps moving instead of freezing
  ([udp](../udp.md)).
- USB sticks appear in Windows as drives, or go whole to Windows. Signature keys and special devices are passed
  whole. Webcams and headsets work in Teams through the RDP channels.
- Nothing runs on the device but the remote desktop: no local desktop, no browser unless you enable the web button.

Questions: [FAQ](../faq.md). Compared with ThinOS and the others: [alternatives](../alternatives.md#dell-thinos).
