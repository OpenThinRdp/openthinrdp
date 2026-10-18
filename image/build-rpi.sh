#!/bin/bash
# Build the OpenThinRDP SD card image for the Raspberry Pi 4 (arm64), see docs/arm.md. Needs Docker or Podman
# (privileged containers), the qemu-user emulation of arm64 on a PC (Debian: qemu-user-binfmt) and ~10 GB of disk.
# Usage: image/build-rpi.sh [site folder]    default: image/site, or image/site.example if it does not exist
# Result: out/openthinrdp-<version>-rpi-arm64.img.xz (+ .sha256): write it to an SD card and boot, nothing to install.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(dirname "$HERE")
SITE=${1:-$HERE/site}; [ -d "$SITE" ] || { echo "No $SITE: building with image/site.example"; SITE=$HERE/site.example; }
[ -f "$SITE/build.conf" ] || { echo "$SITE/build.conf missing"; exit 1; }
ENGINE=$(command -v docker || command -v podman) || { echo "Docker or Podman needed"; exit 1; }
# the packages of the image are configured by their own (arm64) maintainer scripts: on a PC through qemu-user
if [ "$(uname -m)" != aarch64 ] && ! grep -qs '^flags:.*F' /proc/sys/fs/binfmt_misc/qemu-aarch64; then
  echo "This machine cannot run arm64 programs: install the qemu-user emulation (Debian: apt install qemu-user-binfmt)"; exit 1
fi
mkdir -p "$ROOT/out"
# FREERDP_FROM=openthinrdp (default): the arm64 build of the FreeRDP of image/freerdp/freerdp.conf. The prebuilt
# archive of the release when image/freerdp/SHA256SUMS.arm64 names one, otherwise built here (a few hours, once).
if [ "$(sed -n 's/^FREERDP_FROM=//p' "$SITE/build.conf" | tail -1)" = openthinrdp ]; then
  . "$HERE/freerdp/freerdp.conf"
  FD=$ROOT/out/freerdp/$FREERDP_COMMIT-arm64
  if [ ! -f "$FD/SHA256SUMS" ] && [ -s "$HERE/freerdp/SHA256SUMS.arm64" ]; then
    TAR=$(awk '{print $2}' "$HERE/freerdp/SHA256SUMS.arm64")
    echo "Downloading the FreeRDP packages: $FREERDP_RELEASE_URL/$TAR"
    rm -rf "$FD.part"; mkdir -p "$FD.part"
    if curl -fsSL -o "$FD.part/$TAR" "$FREERDP_RELEASE_URL/$TAR" \
       && (cd "$FD.part" && sha256sum -c --quiet "$HERE/freerdp/SHA256SUMS.arm64" && tar -xf "$TAR" && rm "$TAR" && sha256sum -c --quiet SHA256SUMS); then
      rm -rf "$FD"; mv "$FD.part" "$FD"
    else echo "Download failed or the archive does not match SHA256SUMS.arm64: building the packages"; rm -rf "$FD.part"; fi
  fi
  [ -f "$FD/SHA256SUMS" ] || ARCH=arm64 "$HERE/freerdp/build-debs.sh"
fi
# an amd64 container that builds an arm64 system (mmdebstrap --arch=arm64): only the maintainer scripts of the
# packages run emulated, downloads and compression run at full speed
"$ENGINE" run --rm --privileged \
  -v "$ROOT/rootfs":/build/rootfs:ro -v "$HERE":/build/image:ro -v "$SITE":/build/site:ro \
  -v "$ROOT/VERSION":/build/VERSION:ro -v "$ROOT/out":/out \
  debian:trixie bash /build/image/rpi/inside.sh
