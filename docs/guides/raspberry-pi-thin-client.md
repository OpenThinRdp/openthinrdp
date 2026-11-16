# Raspberry Pi as a Remote Desktop thin client

A Raspberry Pi 4 costs little, uses a few watts and is silent: a natural terminal for a Windows desktop. OpenThinRDP
builds as an SD card image for it, the same system as on a PC: the Windows sign-in at power on, RDP over UDP,
sound, USB and the same central management.

**New, and ready for its first boards.** The image is built and tested in emulation (QEMU). Have a Pi 4 and an hour?
Be among the first to run it on a real board: your report puts it in the table below.

- [What works and what to check](#what-works-and-what-to-check)
- [Try it](#try-it)
- [A Pi or a used thin client?](#a-pi-or-a-used-thin-client)

## What works and what to check

- **Boards**: Raspberry Pi 4 Model B with 2 GB or more, the Pi 400 and the CM4. The Pi 5 comes next.
- **The same system as on a PC**: kiosk, settings dialog, management folder, signed updates, FreeRDP with UDP, on
  Debian 13 arm64 with Debian's own kernel.
- **No installer**: the image is written to an SD card or a USB disk and boots as an installed system.
- **Browsers**: Chromium, Firefox or Brave for the web page buttons; Chrome and Edge do not exist for ARM Linux.
- **To check on a real board**: video output on both HDMI ports, sound over HDMI and USB, Wi-Fi and Bluetooth, and
  smoothness of video in the session. The list: [arm.md](../arm.md#first-test-on-a-board).

## Try it

1. Download the image from the [pre-release](https://github.com/OpenThinRdp/openthinrdp/releases/tag/rpi-test-1).
2. Write it to an SD card with Raspberry Pi Imager (*Use custom*), balenaEtcher or `dd`.
3. Start the Pi, set your Windows PC or your RD Connection Broker, sign in.
4. Tell us what worked in the [discussions](https://github.com/OpenThinRdp/openthinrdp/discussions).

## A Pi or a used thin client?

| | Raspberry Pi 4 | Used x86 thin client (Wyse 5070, HP t630, Futro S740) |
|---|---|---|
| Status with OpenThinRDP | new | in production every day |
| Price | the board plus power supply, case and SD card | often less, with case, power supply and storage included |
| Storage | SD card (slower, wears out) or USB disk | eMMC or M.2 |
| Video decoding in the session | first boards will tell | proven |

For a whole office today, a used x86 thin client is the proven choice ([which one](used-thin-client.md)). For a test at
home, or to help the project, the Pi is welcome.
