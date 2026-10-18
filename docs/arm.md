# Raspberry Pi (arm64)

OpenThinRDP also builds as an SD card image for the **Raspberry Pi 4** (Model B, 2 GB or more; the Pi 400 and the
CM4 use the same chip). It is the same system as on a PC (the kiosk, the settings dialog, the management folder,
signed updates, FreeRDP with UDP), on Debian 13 arm64 with Debian's own kernel and Raspberry Pi firmware, like
[Debian's Raspberry Pi images](https://raspi.debian.net/). There is no installer: the image is written to an SD card
(or a USB disk) and boots as an installed system.

**Status: built and tested in emulation (QEMU), not yet on a real board.** What still needs a board is listed at the
end ([First test on a board](#first-test-on-a-board)).

## Building

On a Linux PC (or VM) with Docker or Podman able to run privileged containers, the arm64 emulation of `qemu-user`
and about 10 GB of disk:

```
sudo apt install qemu-user-binfmt        # Debian 13 / Ubuntu; check: grep flags /proc/sys/fs/binfmt_misc/qemu-aarch64 (F)
image/build-rpi.sh [site folder]          # the same site folder as the ISO (image/site, else image/site.example)
```

Result: `out/openthinrdp-<version>-rpi-arm64.img.xz`, its `.sha256`, and `.packages` (the package list of the
image). The build takes about 35 minutes on a 4-core VM (most of it the packages' maintainer scripts under
emulation); an arm64 machine (an arm64 server, a Pi 5) runs it natively. The image is about 540 MB compressed,
2.8 GB written, and holds a 1.7 GB system.

If a build fails with "Exec format error" halfway, the arm64 emulation disappeared under it: a privileged container
that boots systemd (`docker run --privileged ... /sbin/init`) re-registers the binfmt entries of the whole host when
it starts, and for that instant arm64 programs cannot start. `sudo systemctl restart systemd-binfmt` (or reinstalling
`qemu-user-binfmt`) brings the entry back if it is gone; then build again.

With `FREERDP_FROM=openthinrdp` (the default) the image needs the arm64 build of the FreeRDP of
`image/freerdp/freerdp.conf`. `build-rpi.sh` downloads it when `image/freerdp/SHA256SUMS.arm64` names an archive of
the release, otherwise it builds it first:

```
ARCH=arm64 image/freerdp/build-debs.sh    # out/freerdp/<commit>-arm64/, archive out/freerdp/openthinrdp-freerdp-<commit>-arm64.tar
```

The same Debian packaging and pinned commit as amd64, built in an arm64 `debian:trixie` container
(`arm64v8/debian:trixie`, so the local `debian:trixie` image stays amd64). Under emulation it takes about 1.5 hours
on 4 cores (`JOBS=3`) instead of 15-40 minutes; a compile step that could not start because the emulation was
briefly missing (see above) is taken up again where it stopped, up to 3 times. At the end the packages are checked
where they will run: all arm64, installed on a plain Debian 13 arm64 (with trixie-backports, for `libsso-mib0`), and
`xfreerdp3 --buildconfig` shows `WITH_RDPEUDP=ON`. A build whose check failed is kept (`SHA256SUMS.unchecked`, taken
by nothing) and only checked again at the next run. To publish it, attach the archive to the FreeRDP release named in
`freerdp.conf` and put its line in `image/freerdp/SHA256SUMS.arm64`.

The build options of `build.conf` apply as for the ISO (`LOCALE`, `TIMEZONE`, `KEYBOARD`, `ADMIN_PASSWORD_HASH`,
`FREERDP_FROM`, `INCLUDE_BROWSER`, `EXTRA_FIRMWARE`), with two differences: `FIRMWARE` is about PCs and is ignored
(the Pi's own firmware is always there), `AUTO_INSTALL` has nothing to do (no installer).

### How the image is made

`image/build-rpi.sh` runs `image/rpi/inside.sh` in a privileged `debian:trixie` (amd64) container:

1. **mmdebstrap** installs Debian 13 arm64 into a folder: `--variant=important` (what debootstrap, and so
   live-build, installs) plus the packages of `image/lb/packages.list` as they read on arm64, no recommended
   packages, the same dpkg filter as the ISO (no documentation or translations). Only the maintainer scripts of
   the packages run emulated; downloads, unpacking and compression run at full speed.
2. `image/rpi/customize.sh` (a customize hook of mmdebstrap) adds OpenThinRDP exactly as the ISO build does
   (rootfs, site folder, branding, boot splash, FreeRDP), runs **the same chroot hook** as the ISO
   (`image/lb/hook.chroot`: accounts, services, language, security updates, boot splash, initramfs), then what an
   SD card needs instead of an installer: partitions by label, the boot command line, the first-boot growth of
   the root partition, and nothing a device must have of its own (SSH host keys, machine id).
3. The two partitions are made **from the folder**, without loop devices or mounts: `mkfs.vfat` + `mcopy` for the
   firmware partition, `mke2fs -d` for the root file system, written into an MBR disk image with `sfdisk` and
   `dd`, then `xz`.

Why this and not vmdb2 or debos: one shell script in the style of the ISO build, reusing its hook and its package
list; mmdebstrap is the tool Debian's own Raspberry Pi images
([image-specs](https://salsa.debian.org/raspi-team/image-specs)) use under vmdb2, without vmdb2's YAML and its loop
devices and mounts (which need care inside containers); debos needs KVM (fakemachine) or its own workarounds in a
container. Everything here is in Debian 13 (`mmdebstrap`, `dosfstools`, `mtools`, `e2fsprogs`, `fdisk`).

### The package list

`image/lb/packages.list` is one list for both architectures: packages of one architecture only are between
`#if ARCHITECTURES <arch>` and `#endif` (live-build's own syntax, so the ISO build reads it unchanged: the amd64 list
is exactly what it was). PC-only: GRUB, shim, the Intel video driver and `vainfo`, the Intel/AMD graphics and sound
firmware, Intel Wi-Fi firmware. Raspberry Pi only: `linux-image-arm64`, `raspi-firmware`, `firmware-brcm80211` (the
board's Wi-Fi), `fdisk`. Everything else (X, the kiosk, PipeWire, smart cards, network, VPN, TPM libraries, Realtek
USB network firmware) is the same; Chromium is in Debian for arm64 too.

## Writing and first boot

Write the `.img.xz` to an SD card (8 GB or more; a USB disk works too) with any raw image writer: Raspberry Pi
Imager ("Use custom"), balenaEtcher, or `xz -dc openthinrdp-*.img.xz | sudo dd of=/dev/sdX bs=4M conv=fsync`. Put it
in the Pi, connect the monitor (the HDMI port next to the USB-C power, HDMI 0), keyboard, mouse and network, power on.

- The firmware partition (`RASPIFIRM`, FAT32, 512 MB) holds what the Pi's boot firmware reads: `start4.elf`,
  `config.txt`, `cmdline.txt`, the device trees, the kernel and its initramfs. `raspi-firmware` writes them there
  again at every kernel update (also the security updates), from `/etc/default/raspi-firmware`,
  `/etc/default/raspi-extra-cmdline` (the silent boot options) and `/etc/default/raspi-firmware-custom`
  (`disable_splash=1`). Do not edit `config.txt` or `cmdline.txt` by hand: the next kernel update rewrites them.
- The root partition (`RASPIROOT`, ext4) is just larger than the system in the image; at the first boot
  `openthinrdp-growroot` grows it to the whole card (online, a few seconds) and turns itself off.
- Then it is a new device as on a PC: its name becomes `thinclient-<end of the MAC address>`, and the settings
  dialog opens since no broker is set (or the sign-in form, with a `site.conf` that sets one).
- Network names are `eth0` / `wlan0` (`net.ifnames=0`, from raspi-firmware), which the kiosk handles like the
  `en*` / `wl*` names of a PC.

## Updates

Signed update packages work the same way and are the same packages for PCs and Pis:

- `make-update.sh -f` ships the FreeRDP of every architecture that is built: `debs/amd64/` (needed) and
  `debs/arm64/` when `out/freerdp/<commit>-arm64/` exists (otherwise it says so, and arm64 devices keep the FreeRDP
  they have). Packages given with `-d` go in `debs/`.
- `install.sh` (it travels with the package, so devices of any older version run the new one) takes from
  `debs/` and `debs/<architecture>/` only the `.deb` files built for the device's architecture
  (`dpkg --print-architecture`) or for `all`, and installs only the packages of `packages.list` for its
  architecture. A Pi never tries an amd64 package, a PC never tries `raspi-firmware`.
- Going back to an older version (`UPDATE_TO`, `auto-update.sh install <version> downgrade`) puts back the FreeRDP of
  that package by the same rule.
- Kernel and firmware come from Debian (security updates, `SECURITY_UPDATES=on`); `raspi-firmware` copies each new
  kernel and initramfs to the firmware partition.

## What is different from a PC

Read and checked for x86 assumptions: every script of `rootfs/`, the image hook, `install.sh`.

| Area | PC | Raspberry Pi |
|---|---|---|
| Boot | UEFI, shim, GRUB; `boot.sh` makes the GRUB menu silent and the initramfs smaller (`MODULES=dep`) once | Pi firmware, no GRUB: the GRUB part of `boot.sh` is skipped; the silent command line is built into the image; the initramfs stays Debian's (`MODULES=most` with every DRM driver for the splash, about 50 MB with zstd), so the same card boots from SD or USB |
| Secure Boot | signed shim/GRUB/kernel | none (the firmware of the Pi 4 boots whatever is on the card) |
| TPM | secrets of the device sealed in the TPM | no TPM: `SECRETS=file (no TPM)`, root-only files, readable by anyone who takes the SD card out (see below). Nothing waits for a TPM at boot: `secrets.sh` waits for the TPM driver only when the firmware declares a TPM in its ACPI table `TPM2`, and a Pi has no ACPI (checked in QEMU: no wait for `/dev/tpmrm0`). A TPM 2.0 add-on board (SPI, described in the device tree) is not covered: its driver may load after `secrets.sh` has looked, and Debian's `raspi-firmware` does not ship its overlay; untested |
| Boot splash | Plymouth in the initramfs, rebuilt when the site's splash changes | the same; `branding.sh` now treats the Pi image as installed (it has its own initramfs) |
| Scheduled power on (`POWER_ON_TIME`) | RTC wake alarm | the Pi 4 has no RTC: the device logs once "no RTC alarm" and only the scheduled power off works. The clock starts from the last saved time until NTP answers |
| Wake-on-LAN | `wol.sh` | the Pi 4 cannot be woken from power off: `wol.sh` does nothing harmful (it only sets what the driver offers) |
| Video decoding | VA-API on Intel (`intel-media-va-driver`) | none (see [Performance](#performance)) |
| USB disk of the system | — | a Pi often boots from a USB disk: the kiosk never passes the disk the system runs from to Windows (also with `USB_MODE=all` or in `USB_REDIRECT`), `usb-hold.sh` never switches its port off, and `apply.sh` unmounts only USB storage that `usb-mount.sh` mounted in `/media` (it could unmount `/boot/firmware` of a Pi booting from USB when `USB_MODE` changed). The same protects the live system of the ISO running from a stick |
| Display | the driver of the GPU | `vc4` (display) and `v3d` (3D) are two DRM devices: `30-openthinrdp-vc4.conf` makes X use `vc4` (as Raspberry Pi OS does). CMA 256 MB for the display buffers (Debian's default 64 MB is short for 4K or two monitors) |
| 802.1X (`DOT1X`), enterprise Wi-Fi | `wpa_supplicant -D wired` on each wired adapter, `nl80211` for Wi-Fi | the same: the Pi's Ethernet is `eth0` (a wired adapter for `apply.sh` and `dot1x.sh`) and its Wi-Fi `wlan0` (`brcmfmac`, firmware in `firmware-brcm80211`); `openssl` and `wpasupplicant` are in the arm64 list too. Untested on a board |
| `/dev/ttyS0` as COM1 | the PC's serial port | the same rule; on the Pi the serial console is `ttyS1` (pins 8/10) |

**Physical security.** On a PC the TPM keeps the management folder password, the Wi-Fi key and the SSH host keys
away from whoever takes the disk out. A Pi has no TPM and its SD card comes out in a second: anyone holding the card
reads those secrets. Give the management folder account the least rights (as for any image: it can only write the
folder), prefer an 802.1X/WPA2-Enterprise or a separate Wi-Fi for the Pis, and keep them where the card cannot be
taken unseen (a case with the slot covered).

## Performance

A Pi 4 has four Cortex-A72 cores at 1.5-1.8 GHz. RDP graphics are decoded **on the CPU**:

- OpenThinRDP's default graphics (`RDP_GFX=progressive,AVC420:off,AVC444:off`: RemoteFX progressive, no H.264) are
  decoded by FreeRDP's own codecs; the arm64 build has `WITH_SIMD=ON` (FreeRDP's NEON code paths for colour
  conversion and the RemoteFX transforms). Office work on one 1080p monitor is the expected use.
- **No hardware H.264 decoding with FreeRDP on a Pi.** The Pi 4 has an H.264 decoder (1080p60), but Linux reaches it
  only through the V4L2 memory-to-memory driver `bcm2835-codec` of the Raspberry Pi kernel. It is not in mainline
  Linux and not in Debian's kernels: the trixie (6.12) and trixie-backports (7.2) arm64 kernels carry `vc4`, `v3d`,
  `bcm2835-v4l2` (camera), `bcm2835-mmal-vchiq` and `snd-bcm2835`, and no `bcm2835-codec`. On the FreeRDP side the
  arm64 build has `WITH_VIDEO_FFMPEG=ON`, `WITH_OPENH264=OFF`, `WITH_FFMPEG_HWACCEL=OFF`, `WITH_VAAPI=OFF`: H.264
  is decoded by FFmpeg in software, and FreeRDP's FFmpeg hardware path (experimental, off in Debian's build and ours)
  knows VAAPI, VDPAU, CUDA, DRM and the like, not V4L2 memory-to-memory decoders. The Pi 5 has no H.264 decoder at
  all (only HEVC, which RDP does not use). So keep H.264 (AVC420/AVC444) off on Pis, as it is by default; AVC444 is
  two H.264 streams per frame.
- Video in the session (a video call, a YouTube page) is decoded on the server and re-encoded for RDP: the Pi pays
  for the RDP codec, not for the video. Expect fewer frames per second than on an x86 thin client with full-screen
  video, and check `/network:auto`'s adaptation on the first test (see the checklist).
- Two 4K monitors are beyond what a Pi 4 does comfortably; one 1080p or 1440p monitor is the safe target.

## Raspberry Pi 5

Not supported yet, and it does not come for free. What the Debian packages have today (checked in the packages):

- trixie's kernel (6.12) has the Pi 5 device tree (`bcm2712-rpi-5-b.dtb`) but no driver for the RP1 chip, which
  carries the Pi 5's Ethernet, USB ports and GPIO: a Pi 5 would boot it without network, keyboard or mouse.
- trixie-backports' kernel (7.2) has the RP1 drivers (`rp1_pci`, `clk-rp1`, `pinctrl-rp1`, `macb` for the
  Ethernet), but it is packaged in Debian's new layout: the kernel and the device trees are in
  `/usr/lib/modules/<version>/` (`vmlinuz`, `dtb/broadcom/`). trixie's `raspi-firmware` (1.20240424) looks for the
  device trees in `/usr/lib/linux-image-<version>/broadcom/` and would put none on the firmware partition, so that
  kernel does not boot through it as it is. There is no newer `raspi-firmware` in trixie-backports.

The way there: a newer `raspi-firmware` (or a kernel hook of our own that copies kernel, initramfs and device trees
from the new layout), the backports kernel, and a board to check that the Pi 5 boot loader (EEPROM, no `start4.elf`)
takes Debian's kernel through `config.txt`. The Pi 5 also has an RTC (with its battery), so `POWER_ON_TIME` might
work there.

## Tested in emulation

`tests/rpi-qemu.sh` boots the image without a board: the same SD card image, kernel, initramfs and command line
(`cmdline.txt` of its firmware partition), on QEMU's arm64 `virt` machine with a virtio disk, network and screen:

```
tests/rpi-qemu.sh start out/openthinrdp-<version>-rpi-arm64.img.xz /tmp/rpi 4    # a "card" 4 GB larger than the image
tests/rpi-qemu.sh shot /tmp/rpi /tmp/rpi/screen.png
tests/rpi-qemu.sh ssh /tmp/rpi <key> systemctl --failed                           # with SSH=on and the key in the site
tests/rpi-qemu.sh stop /tmp/rpi
```

What it showed with the 0.2.1 image (2 emulated cores, TCG, so every time is about ten times a board's):

- The kernel, initramfs and command line of the firmware partition boot; `root=LABEL=RASPIROOT` is found, systemd
  reaches `graphical.target` with no failed unit (`Startup finished in 14.8s (kernel) + 2min 38s (userspace)`).
- First boot: `openthinrdp-growroot` grew the root partition from 2.3 GB to the 6.4 GB "card" and the file system
  with it; the device named itself `thinclient-123456` from its MAC; SSH with the key of the site; `SECRETS=file (no
  TPM)` and no wait for a TPM (no ACPI on this machine, as on a Pi); `NIC=eth0`; `DOT1X=off`, `dot1x.sh status` off.
- X (modesetting on the virtio screen, software rendering), Openbox and the kiosk start, the background picture and
  then the settings dialog of a new device ("no broker configured: settings dialog opened"), drawn by `ui.py`.
- FreeRDP `3.33.0~udp...+otr1` arm64 is installed and `xfreerdp3 --buildconfig` shows `WITH_RDPEUDP=ON`.
- An update package made by `make-update.sh -f` with both FreeRDP builds: its `install.sh` on the arm64 guest took the
  five packages of `debs/arm64/` (over Debian's 3.32.1 from backports, installed first to see it happen), never the
  amd64 ones, installed the missing packages of the arm64 list, and restarted the kiosk.

Two things seen only because emulation is slow: the first X session started before the device had renamed itself
(the automatic login waits 10 s for it; under TCG the rename came later) and the kiosk came up at the next session,
about 8 minutes after power on; and the console showed systemd's messages before the kiosk instead of the boot
splash. Both are on the checklist below.

What emulation cannot show: the Pi's firmware and its reading of `config.txt`, the SD card controller, HDMI (`vc4`),
the Pi's USB and Ethernet controllers, the Wi-Fi chip, audio, and the speed (TCG emulation is far slower than the
board). QEMU's `raspi4b` machine emulates the SoC but not its PCIe (no USB), Ethernet or a display that Debian's
kernel can drive, so it adds little.

## First test on a board

1. Write the image to an SD card, boot with the monitor on HDMI 0, a USB keyboard and mouse, Ethernet.
2. The boot splash (not systemd's messages), then the settings dialog without a black screen in between: note the
   time from power on to the dialog. A black screen at the first boot only = the rename took longer than the 10 s
   the automatic login waits for it (`/etc/skel/.bash_profile`).
3. `SSH=on` + your key (or the Terminal of the dialog and `su otradmin`), then:
   `df -h /` (the root partition grew to the card), `systemctl --failed` (nothing),
   `journalctl -b -p err`, `cat /boot/firmware/cmdline.txt`, `ls /dev/dri` (card0/card1 and renderD128),
   `grep -i -E "vc4|v3d|glamor" /var/log/Xorg.0.log` (X on vc4 with glamor), `cat /run/openthinrdp-status.txt`.
4. A session: sign in through the broker with UDP (`TRANSPORT=auto`), check `TRANSPORT=... (in use: udp)` in the
   status, move windows, scroll a long document, play a video in the session; watch `top` (FreeRDP's CPU) on SSH.
5. Two monitors (both HDMI ports), a 4K monitor if there is one.
6. USB: a stick (drive in Windows), a smart card reader, a headset (audio both ways), a webcam (`HASCAM` channel).
7. Sound out of HDMI; the 3.5 mm jack (Debian's kernel has `snd-bcm2835`, the firmware-based audio driver from
   staging: check that it loads and that PipeWire shows the jack).
8. Wi-Fi (`WIFI=on`), and a boot from a USB disk instead of the SD card (the same image).
9. An update package made with `make-update.sh -f` (with the arm64 FreeRDP built): it installs, FreeRDP is updated
   to the arm64 build, and the device keeps working after a reboot. A kernel security update: the new kernel lands
   on the firmware partition and boots.
10. Power: a clean shutdown from the kiosk, and the scheduled power off.
