# Getting started: from a USB stick to a managed fleet

Step by step, in the order that works: try it on one device, install it, then set up the management folder and the
manager, and from then on every new device needs only a domain account. About an hour for the whole path, most of
it on the Windows side.

**What you need**: a Windows Remote Desktop target (an RD Connection Broker with session hosts or a Hyper-V VDI
collection, or a single Windows PC or server), a domain account to sign in with, one 64-bit x86 PC or thin client
with 2 GB of RAM, and a USB stick.

## 1. Try it live (10 minutes, nothing installed)

1. Download `openthinrdp-<version>.iso` from the [latest release](https://github.com/OpenThinRdp/openthinrdp/releases/latest)
   and write it to a USB stick (Rufus in DD mode, balenaEtcher or `dd`).
2. Boot the device from the stick. The menu starts the live system after 10 seconds; it never writes to the disk.
3. The **hardware test** runs by itself: processor, memory, disk, graphics, firmware, network, sound, USB, TPM.
   Read it, and if you like, *Send to the OpenThinRDP project* opens a ready-made hardware report on GitHub that you
   send with your own account (nothing in it identifies the device or the network).
4. The settings open: set the **broker** (or the Windows PC) and the **domain** (its full DNS name, e.g.
   `example.local`). If your DHCP does not hand out the DNS servers of the domain, put your domain controllers in
   **Primary DNS** and **Secondary DNS**. Save, sign in with your own account: your Windows desktop opens.

Not working? *Diagnostics* (the ℹ button on the sign-in screen) shows what the device sees; the
[FAQ](../faq.md) has the common cases.

## 2. Install it (3 minutes)

Restart from the stick and choose **Install**: it shows the disk it will erase and asks before writing. It
installs on the first internal disk, never on a USB disk. For many devices, *Unattended install* skips the question.

## 3. The Windows side (once)

- **UDP**: nothing to install. The session hosts accept RDP over UDP by default; keep the Group Policy *Select RDP
  transport protocols* not configured or on "Use both UDP and TCP", and UDP port 3389 open towards the session hosts
  ([details](../udp.md#server-side)).
- **Outside the office**: an RD Gateway or a VPN ([configuration](../configuration.md#rd-gateway)).

## 4. The management folder (once)

1. Create a share on any file server, e.g. `\\fileserver\thinclients`.
2. Create a **domain account only for the devices**, e.g. `svc-thinclient`, never a person's account: every device
   keeps its password.
3. Permissions: the account reads the folder and writes only in `status\`; administrators have full control. The
   manager checks this and, after asking, sets it (step 5). The rules and why: [management.md](../management.md#account).

## 5. The manager (on your Windows PC)

1. Download `openthinrdp-manager-<version>.zip` from the
   [latest release](https://github.com/OpenThinRdp/openthinrdp/releases/latest) and unpack it where only
   administrators can write (a share works: everybody starts the same copy). It updates itself from then on.
2. Start `OpenThinRDP-Manager.vbs` and choose the management folder.
3. **Check permissions** (top bar): it lists what is wrong for the devices' account and offers to correct it.
4. **Settings > Devices**: the settings for every device, at least the **broker** and the **domain** (and the DNS
   servers if your DHCP does not give the domain's). Each one is checked before it is saved; *Edit as text...*
   shows the same file as plain text.
5. **Settings > Manager > Management folder > Name it in the domain**: as a domain administrator, this writes the
   folder for the devices' account in `\\<domain>\NETLOGON\OpenThinRDP\folders.conf`.
6. Optional: the **vault** (the key for the remote screen and for signing updates with your own key), logo and
   background, the **Health Center** for the servers behind the desktops ([manager.md](../manager.md)).

## 6. Every new device from now on

Install it (step 2). In the settings at the first start leave the **management folder empty** and fill in only the
**domain**, the **devices' account** and its **password** (and the DNS servers if your DHCP does not hand them out).
Within five minutes the device finds its folder in the domain, takes the broker and every other setting from
`common.conf`, and appears in the manager. Its event log says `management folder from the domain`.

## 7. Run it

- **Updates**: *Release from GitHub* in the manager, first on **pilot devices**, then *Release to all devices*;
  something broke, *go back* to the previous version in one click ([manager.md](../manager.md#updates-a-few-devices-first-then-all-and-back-when-something-breaks)).
- **Power and commands**: power on with Wake-on-LAN, restart, switch off or run a command on a device.
- **Moving the folder later**: *Settings > Manager > Move the folder...* moves the whole fleet in one step.

What is in production, what is only tested and what does not exist yet: [status.md](../status.md); production
readiness area by area: [maturity.md](../maturity.md).
