# Building the image

Needs a Linux machine (or VM) with Docker or Podman able to run privileged containers, and about 15 GB of
disk. The build runs live-build inside a `debian:trixie` container and takes 10-20 minutes.

```
cp -r image/site.example image/site
# edit image/site/build.conf and image/site/site.conf, add logo.png / splash.png and the rest
image/build.sh
```

Result: `out/openthinrdp-<version>.iso` and its `.sha256`. `image/site/` is ignored by git: it holds your
credentials and keys.

With `FREERDP_FROM=openthinrdp` the build first needs the FreeRDP packages of `image/freerdp/freerdp.conf`:
it downloads the prebuilt ones (checked against `image/freerdp/SHA256SUMS`) or, when they are not published,
builds them with `image/freerdp/build-debs.sh` (15-40 minutes, once: they stay in `out/freerdp/`).

## A Chinese image

`image/site` in this repository is already set up for Simplified Chinese (`LOCALE=zh_CN.UTF-8`,
`TIMEZONE=Asia/Shanghai`, `KEYBOARD=cn`, `LANGUAGE=zh`, `TITLE=远程桌面`). What makes it work, if you build your own:

- `fonts-noto-cjk` in `image/lb/packages.list` (about 45-50 MB in the ISO): without it the screens show empty boxes,
  because DejaVu and Liberation have no ideographs;
- `lang/zh.sh` (398 strings, the same keys as `lang/en.sh`); `tests/run-tests.sh` checks the file's format, that every
  key exists in `en.sh` and that `%s` count matches, for every language;
- `LOCALE` also keeps the gettext folders of the language (`inside.sh`: `/usr/share/locale/zh_CN`), otherwise the
  system is Chinese but the programs still print English.

The installer is then in Chinese too (`language=zh`), but GRUB's menu stays English: GRUB has no CJK glyphs.

The Raspberry Pi 4 SD card image (arm64) is built by `image/build-rpi.sh` from the same site folder, package list and
image hook: see [arm.md](arm.md). Its FreeRDP is the arm64 build of the same commit (`ARCH=arm64
image/freerdp/build-debs.sh`, checked against `image/freerdp/SHA256SUMS.arm64`).

## The site folder

See [image/site.example/README.md](../image/site.example/README.md). In short:

- `build.conf`: `FIRMWARE` (`all`, the default: runs on any PC; `thinclient`: only the usual thin client firmware,
  about 600 MB less), `INCLUDE_BROWSER`, installer language (`LOCALE`), `TIMEZONE`, `KEYBOARD`, `ADMIN_PASSWORD_HASH` (password
  of `otradmin` for `su` in the Terminal of the settings dialog, from `mkpasswd -m yescrypt`; empty = SSH key only), `FREERDP_FROM` (`openthinrdp`, the
  default: FreeRDP with UDP, see [udp.md](udp.md); `backports`, `debian` or `site`), `AUTO_INSTALL`, and `MIRROR` /
  `MIRROR_SECURITY` (your own Debian mirror for a faster build, e.g. `https://mirrors.ustc.edu.cn/debian`; empty = the
  mirror live-build uses).
- `site.conf`: default settings of every device.
- `logo.png` (~200 px, dialogs), `splash.png` (~640 px, transparent, boot screen).
- `ca/*.crt`: certificate authorities for the web button.
- `smb.cred`, `update-key.asc`, `authorized_keys`: management (see [management.md](management.md)).
- `debs/*.deb`: your own packages, e.g. a FreeRDP build.

## Installing

Write the ISO to a USB stick with any raw image writer and boot from it (UEFI). The boot menu shows your splash
on the site colors; its first entry, **Try OpenThinRDP**, starts the live system by itself after 10 seconds and
never writes to the disk. **Install OpenThinRDP** runs the automatic installation on the **first internal disk**:
it shows that disk and asks before writing anything ("No" preselected); never a USB or removable disk (without an
internal disk the installer asks which one). **Unattended install** answers that question too, for rollouts on
known hardware: it **wipes the first internal disk without asking**,
and reboots. With `AUTO_INSTALL=no` the usual Debian installer questions are asked. The menu files are in
`image/lb/bootloaders/grub-pc` (over live-build's templates).

At the first boot of the installed system the device shrinks its initramfs to its own hardware and makes the
boot silent; the settings dialog opens if no broker is set.

## Accounts

| Account | Purpose |
|---|---|
| `kiosk` | runs the X session and the kiosk, logs in automatically on tty1, locked password, may only run `save-config.sh` as root |
| `otradmin` | administration: SSH with a key (`SSH=on`), or `su otradmin` in the Terminal of the settings dialog with `ADMIN_PASSWORD_HASH`, sudo |
| `root` | locked |
