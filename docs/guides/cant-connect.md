# Can't connect? Remote Desktop to your Windows PC, step by step

OpenThinRDP checks why it cannot reach your PC and tells you on its screen; the QR code there brings you here, to the
same case. Almost always the cause is on the Windows PC, and it takes a minute to fix.

**The easiest way: [Prepare the PC](pc-setup.md).** Download it on the Windows PC and open it: it checks Remote
Desktop, the firewall, your account, sleep and the address, fixes what it can with one button, and shows in large type
what to type on the device. Nothing to install.

Or by hand, case by case:

- [The name is not found](#name)
- [Nothing answers at that address](#not-answering)
- [The PC answers, but Remote Desktop does not](#remote-desktop-off)
- [Away from home: another network](#outside)
- [User name or password not valid](#password)
- [Remote Desktop answers, but the connection ends](#other)

<a id="name"></a>

## The name is not found

At home the names of Windows PCs (`DESKTOP-4F7Q2`) are often not known to the network: your router does not tell them
to the other devices. Use the IP address of the PC instead.

1. On the PC open *Settings › Network & internet › Properties* of the connection in use, or type `ipconfig` in a
   Command Prompt, and copy the **IPv4 address**, for example `192.168.1.20`.
2. On the device: **Change the address**, and type it as *Remote computer*.
3. Give the PC a fixed address in your router (*DHCP reservation*, under LAN or DHCP in its settings), so it does not
   change after a restart of the router.

<a id="not-answering"></a>

## Nothing answers at that address

The device asked the network who has that address, and nobody answered.

1. **The PC is on and awake.** Sleep and hibernation take it off the network: move the mouse or press a key on it. To
   keep it reachable, *Settings › System › Power › Sleep* to *Never* when plugged in, or let OpenThinRDP wake it: it
   learns the network card of the PC at the first sign-in and switches it on by itself (Wake-on-LAN).
2. **The address is still the right one.** It can change when the router restarts: `ipconfig` on the PC again.
3. **The PC and the device are on the same network**: the same router, or the same Wi-Fi. A guest Wi-Fi keeps its
   devices apart from the others.

<a id="remote-desktop-off"></a>

## The PC answers, but Remote Desktop does not

The PC is there, but nothing answers on the port of Remote Desktop (3389).

1. **Turn Remote Desktop on**: *Settings › System › Remote Desktop › On*. Windows also opens its firewall for it.
2. **Windows Home cannot receive Remote Desktop.** *Settings › System › About* shows the edition: Pro, Enterprise or
   Education are needed. Home can be upgraded to Pro in *Settings › System › Activation*.
3. **Already on?** A firewall or an antivirus of its own on the PC (Norton, McAfee, Kaspersky, ESET...) may block the
   port: allow *Remote Desktop* or port 3389 in it. If the port was changed on the PC, type it after the address:
   `192.168.1.20:3390`.

<a id="outside"></a>

## Away from home: another network

From outside your home the PC cannot be reached from the internet as it is, and it should not be: opening port 3389
on the router exposes it to the whole internet.

1. **Use Tailscale**, free for personal use: install it on the PC, turn it on in the settings of the device, open the
   link it shows on your phone and sign in with the same account. The device then reaches the PC from anywhere, no
   port opened. See [OpenThinRDP at home](home.md).
2. The PC is on, awake, and Remote Desktop is on.
3. The address is the right one: with Tailscale, the address the Tailscale app shows for the PC (`100.x.y.z`).

<a id="password"></a>

## User name or password not valid

1. **A Microsoft account** (you sign in to Windows with an email): type the email and **its password**. The PIN, the
   face or the fingerprint of Windows Hello are not accepted by Remote Desktop.
2. **Windows 11**: *Settings › Accounts › Sign-in options*, turn off *For improved security, only allow Windows Hello
   sign-in for Microsoft accounts on this device*. With it on, Remote Desktop refuses every password.
3. **Sign in to the PC once with the password** (not the PIN), then try again: Windows checks a Microsoft account
   password only after it has seen it once.
4. **A local account**: the user name on the PC and its password. An account without a password cannot sign in with
   Remote Desktop: set one in *Settings › Accounts › Sign-in options › Password*.
5. Not an administrator of the PC? It has to be in the group *Remote Desktop Users*:
   *Settings › System › Remote Desktop › Remote Desktop users*.

[Prepare the PC](pc-setup.md) does 2 and 5 for you, and tells you which account to type.

<a id="other"></a>

## Remote Desktop answers, but the connection ends

1. **Try again in a minute**: a PC that has just woken up or restarted needs a moment before it accepts a session.
2. **Sign in to the PC once with its password**, then try again.
3. **Restart the PC** if Windows has installed updates.
4. Still not? Ask in the [Discussions](https://github.com/OpenThinRdp/openthinrdp/discussions), with the message the
   device shows and the error number in it: we answer.
