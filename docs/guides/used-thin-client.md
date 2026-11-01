# Which OS for a used thin client? Dell Wyse 5070, HP t630, t640, Fujitsu Futro S740

Used thin clients sell for little once companies replace them, and they are quiet, small and frugal: good
Remote Desktop terminals for an office or for home. Often they come without their operating system, or with a
licence that ended with the old owner (ThinOS, IGEL OS, HP ThinPro). OpenThinRDP is a free thin client OS for
them: install it from a USB stick and the device starts straight into a Windows Remote Desktop sign-in, with no
licence per device.

- [Will my thin client run it?](#will-my-thin-client-run-it)
- [Model by model](#model-by-model)
- [How to install it](#how-to-install-it)
- [Which one to buy](#which-one-to-buy)

## Will my thin client run it?

Yes if it has a **64-bit x86 CPU** (Intel or AMD), **2 GB of RAM** and **8 GB of storage** (none to run it live from a
USB stick). That covers nearly every x86 thin client sold since about 2014. Drivers are not a worry: the system has
the complete Debian 13 kernel and every Debian firmware package ([hardware](../hardware.md)).

Not supported: ARM thin clients, and older ones with a 32-bit only CPU, which Debian 13 no longer runs on.

The quickest test is to start it **live** from a USB stick: nothing is written to the disk, and the hardware test
shows the network card, the address and whether your Windows server answers.

## Model by model

Our production devices are Dell OptiPlex 3000 Thin Clients. The models below meet the requirements but have not
been tested by us yet: if you try one, a line in the
[discussions](https://github.com/OpenThinRdp/openthinrdp/discussions/3) moves it to the tested list.

| Model | CPU | Notes |
|---|---|---|
| **Dell OptiPlex 3000 Thin Client** | Intel Pentium Silver / Celeron | tested: 14 devices in production, sign-in form about 6 s after the firmware |
| **Dell Wyse 5070** | Intel Celeron J4105 / Pentium J5005 | the most common used thin client; RAM and M.2 SATA storage can be upgraded |
| **Dell Wyse 5060** | AMD GX-424CC | older and slower, fine for office work |
| **Dell Wyse 3040** | Intel Atom x5-Z8350, 2 GB soldered | at the minimum: 8 GB eMMC models are tight to install on, run them live or prefer the 16 GB ones |
| **HP t630** | AMD GX-420GI | two RAM slots and M.2 storage, quiet, no fan |
| **HP t640** | AMD Ryzen R1505G | the fastest of this list, the one for video calls and several monitors |
| **HP t620 / t520** | AMD GX series | older, fine for office applications |
| **Fujitsu Futro S740** | Intel Celeron J4105 | popular in Europe, one RAM slot, M.2 SATA |
| **Fujitsu Futro S920 / S940** | AMD GX / Intel Celeron | as above |
| **Any office mini PC** | 64-bit x86 | Lenovo ThinkCentre Tiny, HP EliteDesk Mini, Dell OptiPlex Micro: more than enough |

## How to install it

1. **Download** the [ISO](https://github.com/OpenThinRdp/openthinrdp/releases/latest) and write it to a USB stick
   with Rufus (DD mode), balenaEtcher or `dd`.
2. **Start from the stick.** Usual keys at power on: Dell Wyse F12 (setup F2), HP F9 (setup F10), Fujitsu F12
   (setup F2). Enable USB boot in the setup if the stick is not listed. A Wyse that ran ThinOS often has a BIOS
   password set by its old owner; Dell's support documents the factory one.
3. Try it **live**, then choose **Install**: it shows the disk it will erase and asks first.
4. Set your Windows PC or your RD Connection Broker and sign in.

Coming from Dell ThinOS with many devices: [replacing Dell ThinOS](replace-dell-thinos.md). Coming from an old
PC rather than a thin client: [turning an old PC into a thin client](old-pc-thin-client.md).

## Which one to buy

- **For office work and Remote Desktop**: any of the list. RDP draws the screen on the server; the terminal only
  shows it, so a Celeron is enough.
- **For video calls, video and two large monitors**: a newer CPU helps (HP t640, Wyse 5070 Pentium, OptiPlex 3000).
- **Wi-Fi**: many used thin clients come without the Wi-Fi card. A USB Wi-Fi adapter that works on Debian works here.
- **Storage**: 8 GB is enough to install; a 16 GB or larger module leaves room for updates and the way back.
