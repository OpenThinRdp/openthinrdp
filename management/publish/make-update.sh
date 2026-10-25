#!/bin/bash
# Build and sign an update package for the thin clients, and publish it in the management folder.
#   make-update.sh -v <version> -m <manager folder> [-k <gpg key id>] [-f] [-d <debs folder>] [-s <site folder>] [-o <management folder>]
#     -m  the manager as released, built on Windows by build-release.ps1 of the manager (its own repository): it
#         goes into the zip of the manager with MANIFEST.txt, signed with -k
#     -v  version, must grow (e.g. 0.1.1): devices never install an older one
#     -k  OpenPGP key that signs, in the gpg of this machine: the project key for a release (its public half is
#         rootfs/opt/openthinrdp/keys/openthinrdp-release.asc), or your own key for your own packages (its public
#         half is update-key.asc in the site folder of your image).
#         Without -k nothing is signed here: out/update-<version>/LATEST.txt is signed by the manager with the key
#         kept in its vault (OpenThinRDP-Manager.exe -Sign <path>\LATEST.txt, or Vault > Sign an update), so the
#         signing key never sits on the build machine.
#     -f  ship the FreeRDP with UDP of image/freerdp/freerdp.conf (out/freerdp/<commit>, made by image/build.sh
#         or image/freerdp/build-debs.sh): devices get it when it is newer than theirs. Every architecture built
#         goes in debs/<architecture>/: amd64 (needed), arm64 when out/freerdp/<commit>-arm64 is there
#         (ARCH=arm64 image/freerdp/build-debs.sh); each device installs only its own (install.sh)
#     -d  other .deb files to ship (e.g. your own FreeRDP build): installed only when newer, and only on the
#         devices of their architecture
#     -s  site folder to ship too (site.conf, logos, ca/, update-key.asc, authorized_keys). Never in a release
#     -o  management folder (mounted, e.g. /mnt/thinclients): the package goes to <folder>/updates.
#         Without -o the result stays in out/update-<version>/.
# A release (UPDATE_FROM=github) = the 4 files of out/update-<version>/ (package, manager zip, LATEST.txt and its
# signature) attached to a GitHub release that is not
# a pre-release, signed with the project key:
#   make-update.sh -v 0.1.1 -k <project key> -f      (or without -k, then -Sign in the manager)
#   gh release create v0.1.1 out/update-0.1.1/* --title "OpenThinRDP 0.1.1" --notes "..."
# With -o the index also goes to <folder>/updates/versions/<version>.txt (devices set to that version: UPDATE_TO).
# Needs: bash, tar, gzip, sha256sum, python3 (the zip), gpg (Linux, WSL, or Git Bash with Gpg4win).
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$HERE/../.." && pwd)
V=""; KEY=""; DEBS=""; SITE=""; DEST=""; FRDP=""; MDIR=""
while getopts "v:m:k:fd:s:o:" o; do
  case $o in v) V=$OPTARG ;; m) MDIR=$OPTARG ;; k) KEY=$OPTARG ;; f) FRDP=1 ;; d) DEBS=$OPTARG ;; s) SITE=$OPTARG ;; o) DEST=$OPTARG ;; *) exit 2 ;; esac
done
if [ -n "$FRDP" ]; then
  . "$ROOT/image/freerdp/freerdp.conf"
  FRDP=""   # "<architecture>:<folder>" of every FreeRDP build to ship
  for a in amd64 arm64; do
    d="$ROOT/out/freerdp/$FREERDP_COMMIT"; [ $a = amd64 ] || d="$d-$a"
    if [ ! -f "$d/SHA256SUMS" ]; then
      [ $a = amd64 ] && { echo "no FreeRDP packages in $d: run image/freerdp/build-debs.sh (or image/build.sh) first"; exit 2; }
      echo "no $a FreeRDP packages in $d (ARCH=$a image/freerdp/build-debs.sh): $a devices keep the FreeRDP they have"; continue
    fi
    (cd "$d" && sha256sum -c --quiet SHA256SUMS) || { echo "FreeRDP packages in $d do not match their SHA256SUMS"; exit 2; }
    FRDP="$FRDP $a:$d"
  done
fi
[[ $V =~ ^[0-9A-Za-z._-]+$ ]] || { echo "version missing or not valid (-v)"; exit 2; }
[ -n "$MDIR" ] && [ -f "$MDIR/OpenThinRDP-Manager.core" ] || { echo "the manager as released is missing (-m <folder of build-release.ps1>)"; exit 2; }
[ "$(tr -d '\r\n' < "$MDIR/VERSION")" = "$V" ] || { echo "the manager in $MDIR is not version $V"; exit 2; }
# without a key here the package cannot go to a management folder: it would be published unsigned
[ -n "$KEY" ] || [ -z "$DEST" ] || { echo "-o needs -k: without -k, sign out/update-$V/LATEST.txt in the manager, then copy the 3 files"; exit 2; }
for f in "$ROOT"/rootfs/opt/openthinrdp/*.sh "$ROOT"/rootfs/opt/openthinrdp/lib/*.sh; do bash -n "$f"; done

OUT="$ROOT/out/update-$V"; STAGE=$(mktemp -d); trap 'rm -rf "$STAGE"' EXIT
rm -rf "$OUT"; mkdir -p "$OUT"
cp -a "$ROOT/rootfs" "$STAGE/rootfs"
cp "$HERE/install.sh" "$STAGE/"; echo "$V" > "$STAGE/VERSION"
# the changes, for the update question of a device without a management folder (auto-update.sh notes)
cp "$ROOT/CHANGELOG.md" "$STAGE/"
cp "$ROOT/image/lb/packages.list" "$STAGE/packages.list"
# the project's pictures: install.sh puts them only where a device still shows an older project picture
mkdir -p "$STAGE/project-branding"; cp "$ROOT"/image/branding/logo.png "$ROOT"/image/branding/splash.png "$STAGE/project-branding/"
if [ -n "$DEBS" ]; then mkdir -p "$STAGE/debs"; cp "$DEBS"/*.deb "$STAGE/debs/"; fi
for x in $FRDP; do mkdir -p "$STAGE/debs/${x%%:*}"; cp "${x#*:}"/*.deb "$STAGE/debs/${x%%:*}/"; done
if [ -n "$SITE" ]; then
  mkdir -p "$STAGE/site"
  for f in site.conf logo.png splash.png update-key.asc authorized_keys; do [ -f "$SITE/$f" ] && cp "$SITE/$f" "$STAGE/site/"; done
  if ls "$SITE"/ca/*.crt >/dev/null 2>&1; then mkdir -p "$STAGE/site/ca"; cp "$SITE"/ca/*.crt "$STAGE/site/ca/"; fi
fi
# Unix line endings and modes, whatever the checkout did
find "$STAGE" -type f \( -name '*.sh' -o -name '*.conf' -o -name '*.rules' -o -name '*.service' -o -name '*.timer' \
  -o -name '*.path' -o -name '*.list' -o -name '*.xml' -o -name 'openthinrdp' \) -exec sed -i 's/\r$//' {} +
# modes of the system, whatever the umask or checkout: install.sh copies them onto /, /etc, /opt... (a
# group-writable /etc makes sshd refuse every key)
chmod -R u=rwX,go=rX "$STAGE"
chmod 755 "$STAGE/install.sh" "$STAGE"/rootfs/opt/openthinrdp/*.sh
F="openthinrdp-update-$V.tar.gz"
tar -czf "$OUT/$F" --owner=0 --group=0 -C "$STAGE" .
H=$(sha256sum "$OUT/$F" | cut -c1-64)
# The manager of the same version, for its own update (Update the manager): the files of management/windows and a
# VERSION, not the launcher .exe (built on each PC by build-launcher.ps1) nor anything an administrator made there.
# Its name and hash go into LATEST.txt, so the one signature covers it too.
MZ="openthinrdp-manager-$V.zip"
# MANIFEST.txt in the zip: the SHA-256 of each of its files, and with -k its signature (MANIFEST.txt.sig, the project
# key). The launcher checks them before the manager starts and refuses a changed file (Launcher.cs, Guard).
MF="$OUT/manager-MANIFEST.txt"; rm -f "$MF" "$MF.sig"
python3 - "$MDIR" "$V" "$MF" <<'PY'
import hashlib, os, sys
src, ver, mf = sys.argv[1:4]
skip_ext = ('.exe', '.args', '.old'); skip = {'vault.otr', 'previous', 'VERSION', 'MANIFEST.txt', 'MANIFEST.txt.sig'}
lines = [hashlib.sha256((ver + '\n').encode()).hexdigest() + '  VERSION']
# the launcher itself goes in (the release builds it: no source to build it from), its copy .launcher too
for d, dirs, names in os.walk(src):
    dirs[:] = sorted(x for x in dirs if x not in skip)
    for f in sorted(names):
        if f in skip or f.endswith(skip_ext): continue
        p = os.path.join(d, f)
        lines.append(hashlib.sha256(open(p, 'rb').read()).hexdigest() + '  ' + os.path.relpath(p, src).replace(os.sep, '/'))
open(mf, 'w', newline='\n').write('\n'.join(sorted(lines, key=lambda l: l[66:])) + '\n')
PY
[ -z "$KEY" ] || gpg --batch --yes --local-user "$KEY" --armor --detach-sign -o "$MF.sig" "$MF"
python3 - "$MDIR" "$OUT/$MZ" "$V" "$MF" <<'PY'
import os, sys, zipfile
src, dst, ver, mf = sys.argv[1:5]
# the launcher too: not in MANIFEST.txt (each PC has its own copy), in the zip for a first install
skip_ext = ('.args', '.old'); skip = {'vault.otr', 'previous', 'VERSION', 'MANIFEST.txt', 'MANIFEST.txt.sig'}
with zipfile.ZipFile(dst, 'w', zipfile.ZIP_DEFLATED) as z:
    for d, dirs, names in os.walk(src):
        dirs[:] = sorted(x for x in dirs if x not in skip)
        for f in sorted(names):
            if f in skip or f.endswith(skip_ext): continue
            p = os.path.join(d, f); z.write(p, os.path.relpath(p, src).replace(os.sep, '/'))
    z.writestr('VERSION', ver + '\n')
    z.write(mf, 'MANIFEST.txt')
    if os.path.exists(mf + '.sig'): z.write(mf + '.sig', 'MANIFEST.txt.sig')
PY
rm -f "$MF" "$MF.sig"
MH=$(sha256sum "$OUT/$MZ" | cut -c1-64)
printf 'version=%s\nfile=%s\nsha256=%s\nmanager=%s\nmanager_sha256=%s\n' "$V" "$F" "$H" "$MZ" "$MH" > "$OUT/LATEST.txt"
# The newest major update (a change to how a session connects or runs), from the file MAJOR of the repository: a
# managed device crosses it only once the manager released it (UPDATE_MAJOR), one without a management folder only
# with a yes on its screen. Under the signature, so it cannot be taken away.
MJ=$(grep -v '^#' "$ROOT/MAJOR" 2>/dev/null | tr -d ' \r\n' || true)
if [ -n "$MJ" ]; then
  [[ $MJ =~ ^[0-9A-Za-z._-]+$ ]] || { echo "MAJOR: not a version: $MJ"; exit 2; }
  echo "major=$MJ" >> "$OUT/LATEST.txt"
fi
if [ -z "$KEY" ]; then
  echo "package ready in $OUT, NOT signed yet: OpenThinRDP-Manager.exe -Sign <this folder>\\LATEST.txt (key in the vault)"
  exit 0
fi
gpg --batch --yes --local-user "$KEY" --armor --detach-sign -o "$OUT/LATEST.txt.sig" "$OUT/LATEST.txt"
gpg --batch --verify "$OUT/LATEST.txt.sig" "$OUT/LATEST.txt"
echo "package ready in $OUT"
[ -z "$DEST" ] && exit 0
mkdir -p "$DEST/updates"
# package first, then signature and index: a device never sees an index that points to a missing file
cp "$OUT/$F" "$DEST/updates/"
[ "$(sha256sum "$DEST/updates/$F" | cut -c1-64)" = "$H" ] || { echo "the copy in $DEST/updates is not intact"; exit 1; }
# the index of this version too, for the devices set to it (UPDATE_TO=<version>: pilot groups, going back)
mkdir -p "$DEST/updates/versions"
cp "$OUT/LATEST.txt.sig" "$DEST/updates/versions/$V.txt.sig"; cp "$OUT/LATEST.txt" "$DEST/updates/versions/$V.txt"
cp "$OUT/LATEST.txt.sig" "$DEST/updates/"; cp "$OUT/LATEST.txt" "$DEST/updates/"
# keep the last 3 packages, and every package a device is set to (UPDATE_TO in config\)
KEEP=$(sed -n 's/^UPDATE_TO=\([0-9A-Za-z._-]*\).*/openthinrdp-update-\1.tar.gz/p' "$DEST"/config/*.conf 2>/dev/null | tr -d '\r' | sort -u)
ls -t "$DEST"/updates/openthinrdp-update-*.tar.gz | tail -n +4 | while read -r p; do
  grep -qxF "${p##*/}" <<< "$KEEP" || rm -f "$p"; done
echo "PUBLISHED $V in $DEST/updates"
