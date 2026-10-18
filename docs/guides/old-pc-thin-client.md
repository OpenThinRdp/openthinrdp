# Turning an old PC into a thin client for Windows Remote Desktop

An office PC that is too slow for Windows 11, or a used thin client bought for little, makes a good Remote Desktop
client. OpenThinRDP turns it into a kiosk that starts straight into a sign-in form and opens the user's Windows
desktop in full screen. Nothing is installed on the Windows side and there is no licence per device.

- [What the PC needs](#what-the-pc-needs)
- [What it connects to](#what-it-connects-to)
- [Step by step](#step-by-step)
- [Making it a good thin client](#making-it-a-good-thin-client)
- [When it is not the right choice](#when-it-is-not-the-right-choice)

## What the PC needs

| | |
|---|---|
| CPU | 64-bit x86 (Intel or AMD from about 2010 on). 32-bit only CPUs, such as the first Atoms, cannot run it |
| Firmware | UEFI, with or without Secure Boot, or a legacy BIOS |
| Memory | 2 GB |
| Disk | 8 GB (an old SSD, eMMC or hard disk); none to run it live from a USB stick |
| Network | its own card or Wi-Fi; a USB Ethernet adapter works too |

Drivers are not a worry: the system is Debian 13 with its complete kernel and every firmware package
([hardware](../hardware.md)). The quickest test is to start it live from a stick: if the settings dialog shows an
address, the network works.

## What it connects to

- **A Windows PC with Remote Desktop on**, e.g. the user's office PC (Windows Pro or Enterprise: Home cannot be a
  Remote Desktop host). Set its name as the broker.
- **A Windows Server with Remote Desktop Services**: session hosts or a VDI collection behind an RD Connection
  Broker. Set the broker and the collection.
- **The same, in the cloud** (Azure, AWS or any provider), through an RD Gateway or a VPN
  ([desktops in the cloud](../configuration.md#desktops-in-the-cloud)).

## Step by step

1. **Download** the [ISO](https://github.com/OpenThinRdp/openthinrdp/releases/latest) and write it to a USB stick
   with Rufus (DD mode), balenaEtcher or `dd`.
2. **Start the PC from the stick.** It is usually F12, F11, F9 or Esc at power on; enable USB boot in the firmware
   setup if the stick is not in the list. Turn off "fast boot" if the PC never shows the boot menu.
3. The **live system** starts by itself after 10 seconds. It runs from the stick and writes nothing to the disk.
4. In the **settings dialog** set the broker (or the name of the Windows PC) and the domain. Save, then sign in with
   a Windows account.
5. Happy with it? Restart from the stick and choose **Install**. It shows the disk it is going to erase and asks,
   then takes about three minutes. From then on the PC starts straight into the sign-in form, in a few seconds.

## Making it a good thin client

- **One place for all devices.** Put the settings in a shared folder and use the [manager](../manager.md), with
  updates for a few pilot devices first and a way back.
- **Power.** Set a schedule (`POWER_ON_TIME`, `POWER_OFF_TIME`, `POWER_ON_DAYS`), and set the device to switch off
  when the session ends (`SHUTDOWN_SECS`). Wake-on-LAN needs the firmware option on
  ([configuration](../configuration.md)).
- **The PIN.** A PIN on the settings dialog (⚙) keeps users out of the settings.
- **USB.** Sticks appear in Windows as drives; signature keys and special devices are passed whole; webcams and
  headsets work in Teams.
- **Company networks.** 802.1X on the cable and WPA2/WPA3-Enterprise Wi-Fi are supported.

## When it is not the right choice

- **The user also needs local programs**: a normal Linux desktop with a Remote Desktop client is better.
- **Citrix or Omnissa Horizon**: OpenThinRDP does RDP only.
- **Azure Virtual Desktop or Windows 365**: not supported yet.

Questions: [FAQ](../faq.md). Compared with Linux Mint + Remmina and the thin client systems:
[alternatives](../alternatives.md).
