# Which PCs and thin clients run OpenThinRDP?

Any 64-bit x86 PC or thin client with 2 GB of RAM: an old office PC or laptop, a mini PC, a used Dell Wyse 5070,
HP t630 or t640, Fujitsu Futro S740. Model by model: [which OS for a used thin client](guides/used-thin-client.md).

## Drivers: all of Debian's

OpenThinRDP is light because it runs no desktop, not because drivers were left out. The downloadable ISO carries
the **complete Debian 13 kernel (Linux 6.12) with every driver module, and every firmware package Debian has**
(`firmware-linux-nonfree`, `firmware-realtek`, `firmware-iwlwifi`, `firmware-atheros`, `firmware-brcm80211`,
`firmware-mediatek`, `firmware-amd-graphics`, `firmware-intel-graphics`, `firmware-sof-signed` and the others: the
`FIRMWARE=all` build of [building.md](building.md)). A network card, Wi-Fi adapter or graphics chip that works with
Debian 13, or with the Ubuntu and Linux Mint releases of the same period, works the same here. Only an image you
build yourself with `FIRMWARE=thinclient` keeps just the usual thin client firmware, to save about 600 MB.

The quickest way to know: start the ISO **live** from a USB stick. Nothing is written to the disk, and the
diagnostics (ℹ on the sign-in screen) show the network card, the address and whether the brokers answer.

## Requirements

| | |
|---|---|
| CPU | 64-bit x86 (x86-64): Intel, AMD, VIA |
| Firmware | UEFI, with or without Secure Boot, or a legacy BIOS |
| Memory | 2 GB |
| Storage | 8 GB to install; none to run it live from a USB stick |

## Tested

| Device | Firmware | Notes |
|---|---|---|
| Dell OptiPlex 3000 Thin Client (Intel Pentium Silver/Celeron, eMMC, Realtek NIC, Intel Wi-Fi) | UEFI, Secure Boot | the production fleet: 15 devices, boot to sign-in form in about 6 s after the firmware |
| QEMU/KVM virtual machine (OVMF) | UEFI, Secure Boot | every release: live system, automatic and confirmed installation, first update |
| QEMU/KVM virtual machine (SeaBIOS) | legacy BIOS | live system and installation |

## Already running it

Outside our fleet OpenThinRDP already runs on 39 different models, among them:

| Family | Models |
|---|---|
| HP | t520, t530, t620, t655 |
| Dell Wyse | 5070 |
| Centerm | thin clients |
| PCs | mini PCs and laptops |
| Virtual machines | Hyper-V, VMware, Proxmox, VirtualBox |

## Ready for it: models that meet the requirements

These common used thin clients have a 64-bit CPU, 2 GB of RAM or more and 8 GB of storage or more: everything
OpenThinRDP needs. Running one? A line in the [discussions](https://github.com/OpenThinRdp/openthinrdp/discussions/3)
(model, how it went) moves it to the tables above.

| Family | Examples |
|---|---|
| Dell Wyse | 3040, 5060, 5470 |
| HP | t630, t640, t540 |
| Fujitsu Futro | S740, S940, S920 |
| Lenovo, IGEL and others | ThinCentre M625q, IGEL UD3 (x86-64 models), any office mini PC |

Some of them ship with less storage than 8 GB in their smallest version: run them live from a USB stick or put in a
bigger module.

## Raspberry Pi and other processors

**Raspberry Pi 4** (arm64), new: an SD card image built by `image/build-rpi.sh`
([pre-release](https://github.com/OpenThinRdp/openthinrdp/releases/tag/rpi-test-1)), tested in QEMU arm64 emulation
and ready for its first real boards. What is different from a PC and what to check on the first board: [arm.md](arm.md).

The Raspberry Pi 5 and ARM thin clients come after the Pi 4. Debian 13 runs on 64-bit processors, so the oldest
32-bit only Atom and VIA models stay out.

## Firmware settings (Dell)

- **Wake-on-LAN**: enable "Wake on LAN" and **disable "Deep Sleep Control"**. With deep sleep in S4/S5 the
  network card is off and the magic packet never arrives. The same setting blocks the RTC alarm used by
  `POWER_ON_TIME`.
- **AC Recovery** (Power Management): **On** for a device with `POWER_ON_TIME`. With Off (the default) a device
  that loses power stays off when it comes back, and the alarm of `POWER_ON_TIME` goes with the power: it does not
  wake the next morning. With On it starts when the power comes back; outside its hours OpenThinRDP warns for 60 s
  (with Cancel) and switches off, with the alarm set again. The report of the device says it (`FW_AC_RECOVERY`).
- **USB boot** must be enabled to install from a stick (Integrated Devices).
- On Linux the settings can be changed without entering the setup screen, through `dell-wmi-sysman`
  (`/sys/class/firmware-attributes/dell-wmi-sysman/`), with the BIOS admin password if one is set.

## Monitors

- A monitor switched on after the thin client (or a slow HDMI/DisplayPort link) leaves X without an output:
  the kiosk checks every 2 s and enables it.
- Monitors with a built-in USB hub may expose a "Hub Controller" device: it is kept local.
- Touch monitors stay local and their touches go to Windows as real touch input (`+multitouch`).

## USB devices seen in the field

- Webcams with microphone (UVC + audio): camera through the RDP camera channel, microphone through the RDP audio
  channel (tested with an eMeet Nova and an HD Web Camera 05a3:9331 against Windows 11 and Zoom).
- Signature keys with smart card reader + storage: the reader goes through the smart card channel, the
  storage as a whole device.
- Composite devices that restart in another mode once they see a PC (e.g. tachograph download keys): passed
  with `/usb:auto`, so they are passed again after re-enumeration. Devices plugged in during the session are
  passed only with a FreeRDP that has the `filter:` option of the USB channel (merged upstream after 3.32.1);
  with older versions plug them in before signing in, or list them in `USB_REDIRECT`.
- USB network adapters are never passed (the device would lose its own network).
