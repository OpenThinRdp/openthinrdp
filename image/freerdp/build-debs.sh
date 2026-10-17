#!/bin/bash
# Build the FreeRDP packages of OpenThinRDP (see freerdp.conf). Needs Docker or Podman, ~6 GB of disk, and
# 15-40 minutes. The image build (FREERDP_FROM=openthinrdp) runs it on its own when the packages are missing.
# Usage: image/freerdp/build-debs.sh                 packages for amd64 (the PC image)
#        ARCH=arm64 image/freerdp/build-debs.sh      packages for arm64 (the Raspberry Pi image, docs/arm.md)
# Result: out/freerdp/<commit>/*.deb (the packages a thin client needs), debug/*.deb (debug symbols), SHA256SUMS;
# for arm64 the same in out/freerdp/<commit>-arm64/.
# arm64 is built in an arm64 debian:trixie container: on a PC that needs the qemu-user emulation of the kernel
# (Debian: apt install qemu-user-binfmt, the binfmt entry must have the F flag), and takes a few hours.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
. "$HERE/freerdp.conf"
ARCH=${ARCH:-amd64}
# amd64 keeps the names it always had; another architecture gets "-<arch>" after the folder and the archive. Its
# container image is the arm64 repository of the official Debian image, not "debian:trixie" with --platform: with
# Docker's classic image store that would make the local "debian:trixie" an arm64 image for every later build.
case $ARCH in
  amd64) SUF=""; IMG=debian:trixie; PLAT=() ;;
  arm64) SUF=-arm64; IMG=arm64v8/debian:trixie; PLAT=(--platform linux/arm64) ;;
  *) echo "ARCH must be amd64 or arm64"; exit 2 ;;
esac
OUT=$ROOT/out/freerdp/$FREERDP_COMMIT$SUF
[ -f "$OUT/SHA256SUMS" ] && { echo "Already built: $OUT"; exit 0; }
ENGINE=$(command -v docker || command -v podman) || { echo "Docker or Podman needed"; exit 1; }
if [ "$ARCH" != amd64 ] && [ "$(uname -m)" != aarch64 ]; then
  "$ENGINE" run --rm "${PLAT[@]}" "$IMG" true 2>/dev/null \
    || { echo "this machine cannot run $ARCH containers: install the qemu-user emulation (Debian: qemu-user-binfmt)"; exit 1; }
fi
mkdir -p "$OUT"
"$ENGINE" run --rm "${PLAT[@]}" -e FREERDP_REPO="$FREERDP_REPO" -e FREERDP_COMMIT="$FREERDP_COMMIT" \
  -e FREERDP_VERSION_BASE="$FREERDP_VERSION_BASE" -e FREERDP_OTR_REVISION="$FREERDP_OTR_REVISION" \
  ${JOBS:+-e JOBS="$JOBS"} ${PLAT:+-e RETRIES=3} -v "$HERE/inside-debs.sh":/inside-debs.sh:ro -v "$OUT":/out "$IMG" bash /inside-debs.sh
if [ "$ARCH" != amd64 ]; then
  # a cross-architecture build is checked where it will run: the packages are of that architecture, they install
  # together on a plain Debian 13 of it, and the client has the UDP transport
  "$ENGINE" run --rm "${PLAT[@]}" -e ARCH="$ARCH" -v "$OUT":/out:ro "$IMG" bash -c '
    set -e; for d in /out/*.deb; do a=$(dpkg-deb -f "$d" Architecture)
      [ "$a" = "$ARCH" ] || [ "$a" = all ] || { echo "${d##*/} is for $a, not $ARCH"; exit 1; }; done
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends /out/*.deb >/dev/null
    echo "$(uname -m): $(xfreerdp3 --version | head -1)"
    xfreerdp3 --buildconfig | grep -o "WITH_RDPEUDP=ON" || { echo "no UDP transport in this build"; exit 1; }' \
    || { echo "the $ARCH packages in $OUT failed their check"; rm -f "$OUT/SHA256SUMS"; exit 1; }
fi
# one archive to attach to a release (package names have "~" and "+", which release asset names do not keep)
TAR=openthinrdp-freerdp-${FREERDP_COMMIT:0:9}$SUF.tar
(cd "$OUT" && tar -cf "../$TAR" *.deb SHA256SUMS)
echo "Packages in $OUT, release archive out/freerdp/$TAR"
if [ "$ARCH" = amd64 ]; then echo "Its line for image/freerdp/SHA256SUMS: $(cd "$OUT/.." && sha256sum "$TAR")"
else echo "Its line for image/freerdp/SHA256SUMS.$ARCH: $(cd "$OUT/.." && sha256sum "$TAR")"; fi
