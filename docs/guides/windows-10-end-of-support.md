# Windows 10 end of support: keep the old PCs as Remote Desktop terminals

Windows 10 support ended on 14 October 2025, and the extended security updates for home users ended a year later.
Many PCs cannot run Windows 11 (no TPM 2.0, a CPU older than the list). They still work, but connecting them to the
Internet without security updates is a risk.

There is a third way between throwing them away and keeping them unpatched: turn them into **terminals for a
Windows that is up to date**. OpenThinRDP replaces Windows 10 on the old PC with a small, locked-down system that is
kept up to date by itself and opens a Windows 11 or Windows Server desktop over Remote Desktop. The work, the
programs and the data stay on the up-to-date computer; the old PC only shows the screen.

- [Does it fit my case?](#does-it-fit-my-case)
- [What you need](#what-you-need)
- [How to do it](#how-to-do-it)
- [What it saves](#what-it-saves)

## Does it fit my case?

| You have | Connect the old PCs to |
|---|---|
| **At home**: one newer PC with Windows 11 Pro, and an old laptop | that PC: the laptop becomes a second screen of it, in another room or from outside ([at home](home.md)) |
| **A small office**: one Windows Server or a few Windows 11 Pro PCs | Remote Desktop Services on the server, or each user's PC |
| **A company with a domain**: RDS or VDI on Hyper-V, Proxmox or VMware | the RD Connection Broker: the old PCs become a managed fleet of thin clients ([getting started](getting-started.md)) |

It does not fit when the old PC must run programs on its own with no other Windows to connect to: then the
options are Windows 11 on supported hardware, or a Linux desktop.

## What you need

- The old PC: 64-bit x86, 2 GB of RAM, 8 GB of disk; nearly every PC that ran Windows 10 qualifies
  ([hardware](../hardware.md)).
- A Windows that accepts Remote Desktop: Windows 11 Pro, Enterprise or Education, Windows Server, or a Windows
  virtual machine. Windows Home cannot be connected to.
- In a company: the Remote Desktop licences (RDS CALs) your server already needs for any client; OpenThinRDP adds
  no licence of its own.

## How to do it

1. Write the [ISO](https://github.com/OpenThinRdp/openthinrdp/releases/latest) to a USB stick and start the old
   PC from it. It runs live: nothing is written to the disk.
2. Choose *Workgroup* (home, small office) or *Domain*, set the computer or the broker to connect to, and sign in.
3. Happy with it? *Install* replaces Windows 10 on the disk, or *Install alongside Windows* keeps it on a laptop
   that still has room.

Step by step: [turning an old PC into a thin client](old-pc-thin-client.md).

## What it saves

- **New hardware**: the old PCs keep working for years; a terminal needs far less than a full Windows PC.
- **Updates on every PC**: Windows, programs and antivirus are updated in one place, on the server or the main PC.
  The terminals update themselves, with signed packages and a way back.
- **Licences**: no cost per device, no subscription, no account ([is it free?](../faq.md#is-it-free)).
