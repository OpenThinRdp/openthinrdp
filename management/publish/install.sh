#!/bin/bash
# Installer inside every update package (run by auto-update.sh as root, from the unpacked package).
# Brings an installed thin client to the files of the package without interrupting a remote session:
# if a session is open, the new kiosk starts at the next sign-in or boot.
set -u
cd "$(dirname "$0")"
OTR=/opt/openthinrdp
log(){ echo "$(date '+%H:%M:%S') $*"; }
log "### $(hostname), remote sessions open: $(pgrep -c xfreerdp3)"
# progress for the screens of the device (ui.py): "percent version"
prog(){ echo "$1 $(cat VERSION 2>/dev/null)" > /run/openthinrdp-update-progress 2>/dev/null; }
prog 5

# 1) everything must be valid before anything is touched
for f in rootfs/opt/openthinrdp/*.sh rootfs/opt/openthinrdp/lib/*.sh rootfs/opt/openthinrdp/lang/*.sh; do
  bash -n "$f" || { log "ERROR: syntax of $f"; exit 1; }
done
visudo -cqf rootfs/etc/sudoers.d/openthinrdp || { log "ERROR: sudoers file not valid"; exit 1; }
# the helpers of the NEW version (package list and .deb files by architecture)
. rootfs/opt/openthinrdp/lib/common.sh
ARCH=$(otr_arch)

prog 15
# 2) Debian packages the new version needs and that are missing (needs the Debian mirror). Those of this
# architecture only: packages.list keeps the PC-only ones (GRUB, Intel drivers) and the Raspberry Pi ones apart.
if [ -f packages.list ]; then
  MISSING=$(pkg_list "$ARCH" packages.list | while read -r p; do dpkg -s "$p" >/dev/null 2>&1 || echo "$p"; done | tr '\n' ' ')
  if [ -n "${MISSING// /}" ]; then
    log "installing missing packages: $MISSING"
    apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null 2>&1
    # without the recommended packages, as the image is built: wireguard-tools recommends wireguard-modules, which on
    # a device without a Debian kernel package would bring a second kernel
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q --no-install-recommends $MISSING >/dev/null 2>&1 || log "WARNING: some packages could not be installed: $MISSING"
  fi
fi

prog 40
# 3) .deb files shipped in the package (e.g. a FreeRDP build): only when newer than the installed ones.
# /etc/openthinrdp/freerdp-pinned (with the reason inside) keeps FreeRDP as it is on this device.
# debs/*.deb and debs/<architecture>/*.deb (make-update.sh -f: FreeRDP for amd64 and arm64), only those built for
# this architecture or for all.
DEBS=$(pkg_debs .)
if [ -n "$DEBS" ]; then
  INST=()
  for d in $DEBS; do
    n=$(dpkg-deb -f "$d" Package); v=$(dpkg-deb -f "$d" Version); cur=$(dpkg-query -W -f '${Version}' "$n" 2>/dev/null)
    if [[ $n == *freerdp* || $n == *winpr* ]] && [ -f /etc/openthinrdp/freerdp-pinned ]; then
      log "$n not updated: pinned ($(head -1 /etc/openthinrdp/freerdp-pinned))"; continue
    fi
    { [ -z "$cur" ] || dpkg --compare-versions "$v" gt "$cur"; } && INST+=("$d")   # ./debs/...: a path for apt
  done
  if [ ${#INST[@]} -gt 0 ]; then
    apt-get -o DPkg::Lock::Timeout=300 update -q >/dev/null 2>&1
    if DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -q "${INST[@]}" >/dev/null 2>&1; then log "installed: ${INST[*]}"
    else log "ERROR: installing ${INST[*]}"; exit 1; fi
  fi
fi

prog 75
# 4) files: the whole rootfs of the package. The device settings (/etc/openthinrdp/openthinrdp.conf,
# smb.cred, keys) are not in the rootfs, so they are never overwritten.
# cp -a also gives /, /etc, /opt... the modes of the package's folders: always 755/644 here, whatever the package
# was built with. This also repairs a device that got the 0.1.1 package built with umask 002 (/etc group-writable:
# sshd refused every key).
chmod -R u=rwX,go=rX rootfs
cp -a --no-preserve=ownership rootfs/. /
chmod 755 $OTR/*.sh; chmod 0440 /etc/sudoers.d/openthinrdp
# files of older versions that were renamed or dropped
rm -f /etc/udev/rules.d/60-openthinrdp-link-up.rules   # 0.1.8: 90-openthinrdp-net.rules
# /etc/skel only reaches new accounts: the kiosk account gets its Openbox settings here
install -D -m644 -o kiosk -g kiosk rootfs/etc/skel/.config/openbox/rc.xml /home/kiosk/.config/openbox/rc.xml
[ -f VERSION ] && cp VERSION $OTR/VERSION
# pictures of the project (logo, boot splash): a device still showing an OLDER project picture gets the current
# one. Only a file that is exactly a known project picture is replaced, so the pictures of your own image stay.
# When image/branding changes, add the sha256 of the pictures being replaced here.
PROJECT_PICTURES="f74ab1f03903e282fe309fcde20b72d74980f53317f5346cd330a550703641db db53949e775da810e22110aaea8c70f927da77d8bd43b5fcbe09a49bc8590366
  c0164681359bdf3bc6c2ca16c42fb633232b467725be9acc082dd287f269dcd0 502303aede93b009d1dd7dfb294478de11da555a7bf8817d0c2d53ea43f05270"
for f in logo splash; do
  [ -f project-branding/$f.png ] && [ -f $OTR/branding/$f.png ] || continue
  h=$(sha256sum < $OTR/branding/$f.png | cut -c1-64)
  if [[ " $(echo $PROJECT_PICTURES) " == *" $h "* ]] && ! cmp -s project-branding/$f.png $OTR/branding/$f.png; then
    install -m644 project-branding/$f.png $OTR/branding/$f.png; log "$f.png: the current picture of the project"
  fi
done
# site files, when the package carries them (make-update.sh -s)
if [ -d site ]; then
  [ -f site/site.conf ] && install -m644 site/site.conf /etc/openthinrdp/site.conf
  for f in logo splash; do [ -f site/$f.png ] && install -m644 site/$f.png $OTR/branding/$f.png; done
  # the boot splash follows by itself (branding.sh splash, at the next report): it rebuilds the initramfs
  ls site/ca/*.crt >/dev/null 2>&1 && { mkdir -p /etc/openthinrdp/ca; install -m644 site/ca/*.crt /etc/openthinrdp/ca/; }
  [ -f site/update-key.asc ] && install -m644 site/update-key.asc /etc/openthinrdp/update-key.asc
  [ -f site/authorized_keys ] && install -m644 site/authorized_keys /etc/openthinrdp/authorized_keys
fi

prog 88
# 5) services, rules and settings applied again
systemctl daemon-reload
systemctl enable openthinrdp-secrets.service openthinrdp-boot.service openthinrdp-wol.service openthinrdp-report.timer openthinrdp-report.path openthinrdp-schedule.timer openthinrdp-keep-log.service >/dev/null 2>&1
systemctl start openthinrdp-report.timer openthinrdp-report.path openthinrdp-schedule.timer openthinrdp-keep-log.service >/dev/null 2>&1
udevadm control --reload; udevadm trigger --subsystem-match=input --action=change
$OTR/security-updates.sh >/dev/null
$OTR/browser-policy.sh
$OTR/apply.sh now
pgrep -x openbox >/dev/null && runuser -u kiosk -- env DISPLAY=:0 openbox --reconfigure >/dev/null 2>&1

prog 98
# 6) the new kiosk: at once if nobody is connected (restart of the X session, synchronous: started in the
# background inside the update unit it would be killed when the unit ends), otherwise as soon as the open session
# is over (kiosk-after-session.sh, in a unit of its own) or at the next start
# the Shut down button was pressed during the install: no restart (it would kill the kiosk that waits to switch off)
if [ -f /tmp/openthinrdp-poweroff-pending ]; then log "power off requested during the install: auto-update.sh switches off"
elif pgrep -x xfreerdp3 >/dev/null; then
  if systemd-run --unit=openthinrdp-kiosk-after-session --collect "$OTR/kiosk-after-session.sh" >/dev/null 2>&1; then
    log "remote session open: new kiosk when it is over"
  else log "remote session open: new kiosk at the next start"; fi
else log "restarting the X session with the new kiosk"; sleep 1; pkill -x Xorg; fi
exit 0
