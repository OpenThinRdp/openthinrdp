# Prepare the PC: Remote Desktop on your Windows PC in one click

**Prepare the PC** is a small free program for the Windows PC you want to reach from OpenThinRDP. Open it, press
**Fix everything**, and it shows in large type what to type on the device: nothing to install, nothing to know.

**[⬇ Download Prepare the PC](https://github.com/OpenThinRdp/openthinrdp-manager/releases/download/pc-setup-v1.0.0/OpenThinRDP-PC-Setup.exe)**
(Windows 10 and 11, one file)

## What it checks, and fixes

| Check | Fixed by the button |
|---|---|
| The edition of Windows: Home cannot receive Remote Desktop | No: it tells you that Windows Pro is needed |
| Remote Desktop on, and its service waiting for connections | Yes |
| The Windows firewall allows Remote Desktop on this network | Yes |
| Your account: a Microsoft account (sign in with its email), a local account without a password | It tells you |
| Windows 11 allows only Windows Hello for Microsoft accounts: Remote Desktop needs the password | Yes |
| Your account may connect remotely (administrator, or in *Remote Desktop Users*) | Yes |
| The PC goes to sleep on mains power, and the device can no longer reach it | Yes, never on mains power |
| The address of the PC, and whether the router may change it | It tells you |

Windows asks for the administrator confirmation only when you press **Fix everything**.

## What to type on the device

At the end the window says it in large type, for example:

| On the device | Type |
|---|---|
| Kind of setup | Without a domain |
| Remote computer | `192.168.1.20` |
| User | `mario.rossi@outlook.com` |
| Password | the password of the Microsoft account, not the PIN |

With Tailscale on the PC it also shows the address to use away from home.

## "Windows protected your PC"

The program is signed by the project, not by a company Windows already knows, so the first time Windows may show a
blue window *Windows protected your PC*: press **More info**, then **Run anyway**. It is published with the free
manager, in [its releases on GitHub](https://github.com/OpenThinRdp/openthinrdp-manager/releases). It changes only what
the window lists, and only when you press **Fix everything**.

## Anonymous data

A box on the window, ticked, sends to the project which checks were not right and what was fixed, once, when the
window closes: never a name, an address or an account. Untick it to send nothing. See [Privacy](../privacy.md).

Still not connecting? [Can't connect?](cant-connect.md) goes through every case.
