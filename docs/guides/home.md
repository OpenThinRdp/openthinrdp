# OpenThinRDP at home: an old laptop as a terminal for your Windows PC

OpenThinRDP turns an old laptop, a mini PC or a Raspberry Pi into a terminal for the Windows computer you already
have: a desktop PC in the study, a virtual machine on Hyper-V or Proxmox, the PC at the office. You sign in and get
your Windows desktop with sound, microphone, webcam and USB keys; nothing is kept on the terminal.

No domain, no server, no subscription. At the first start choose **Workgroup** and fill in two fields.

- [Set up in two minutes](#set-up-in-two-minutes)
- [It feels like a computer of your own](#it-feels-like-a-computer-of-your-own)
- [From outside, with Tailscale](#from-outside-with-tailscale)
- [Try it without touching the disk, keep it if you like it](#try-it-without-touching-the-disk-keep-it-if-you-like-it)
- [What you need to know](#what-you-need-to-know)

## Set up in two minutes

1. [Download the ISO](https://github.com/OpenThinRdp/openthinrdp/releases/latest), write it to a USB stick (Rufus,
   balenaEtcher or `dd`) and start the old computer from it.
2. Choose **Workgroup (no domain)**.
3. Pick your PC from the list: OpenThinRDP finds the computers of your network with Remote Desktop on.
4. Sign in with your Windows user. With a Microsoft account: its email address and password (the Windows Hello PIN
   is not accepted by Remote Desktop).

Remote Desktop must be on in Windows: *Settings > System > Remote Desktop* (Windows Pro, Enterprise or Education).

## It feels like a computer of your own

- **Password remembered**: at power on your desktop opens by itself. Kept in the TPM when the computer has one.
- **Your PC switched off? It is switched on**: OpenThinRDP learns its network card at the first sign-in and wakes it
  up with Wake-on-LAN, then connects as soon as Windows answers.
- **More than one computer**: the PC in the study and a virtual machine, chosen at sign-in.
- **Bluetooth**: headsets, keyboards and mice paired from the settings.
- **A browser only if you want one**: none is installed until you turn on a web page, then only the one you choose
  (Chromium, Firefox, Brave, Chrome or Edge), kept up to date.

## From outside, with Tailscale

Turn on Tailscale in the settings: the terminal shows a link, open it on your phone and sign in with your Tailscale
account. From then on the laptop reaches your PC at home from anywhere, without opening ports on the router.
Tailscale is free for personal use, and it is installed on the terminal only when you turn it on.

## Try it without touching the disk, keep it if you like it

- **The USB stick keeps your settings**: started from a stick, OpenThinRDP makes room for them on the stick itself,
  as other live systems do. Updates, Wi-Fi and your settings stay from one start to the next.
- **Install it alongside Windows**: on a laptop that still has Windows, shrink the Windows partition (*Disk
  Management > Shrink Volume*) and choose *Install alongside Windows*: the boot menu offers both, nothing is erased.
- **Or install it on the whole disk**: an old laptop starts in a few seconds and keeps itself up to date.

## What you need to know

- The Windows you connect to must accept Remote Desktop: Windows Home does not (Pro, Enterprise, Education and
  Windows Server do). A virtual machine usually already does.
- Wake-on-LAN works when the PC's network card and BIOS allow it, over a cable. A PC on Wi-Fi can rarely be woken.
- Your remembered password is sealed in the TPM when the terminal has one; on a computer without a TPM, or on a USB
  stick, it is kept on the device, readable by its administrator only. If someone else can take your stick, leave
  *Remember password* off.
- What only some people use (the browser, Tailscale, Bluetooth) is installed the first time you turn it on, so the
  terminal needs the Internet that first time.
- Chrome and Edge exist for PCs only; on a Raspberry Pi choose Chromium, Firefox or Brave.

Questions and ideas: [Discussions](https://github.com/OpenThinRdp/openthinrdp/discussions).
