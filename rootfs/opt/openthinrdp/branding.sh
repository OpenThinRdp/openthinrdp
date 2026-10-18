#!/bin/bash
# Logo and background picture from the management folder, and the boot splash. Runs as root.
#   branding.sh sync <mounted folder>   config\branding\<hostname>\<x>.png, else config\branding\<x>.png,
#                                       else the image's own: copied to /var/lib/openthinrdp/branding. The logo
#                                       goes into the dialogs, splash.png behind the sign-in form.
#   branding.sh splash                  the boot splash (Plymouth) always shows the image's own picture and colors
#                                       (site.conf/defaults), never the management folder's: a device that took
#                                       the folder's picture there (0.1.1) gets it back, the initramfs is rebuilt
#                                       in the background (installed system only)
. /opt/openthinrdp/lib/common.sh
BR=$OTR_LIB/branding
THEME=/usr/share/plymouth/themes/openthinrdp

# a PNG no larger than 2 MB and MAXW x MAXH pixels (width and height from the IHDR chunk)
png_ok(){ local f=$1 maxw=$2 maxh=$3 w h
  [ -f "$f" ] && [ "$(stat -c %s "$f")" -le 2097152 ] || return 1
  [ "$(od -An -tx1 -N8 "$f" | tr -d ' \n')" = 89504e470d0a1a0a ] || return 1
  w=$(od -An -tu1 -j16 -N4 "$f" | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')
  h=$(od -An -tu1 -j20 -N4 "$f" | awk '{print $1*16777216 + $2*65536 + $3*256 + $4}')
  [ "$w" -ge 1 ] && [ "$w" -le "$maxw" ] && [ "$h" -ge 1 ] && [ "$h" -le "$maxh" ]
}
# #rrggbb -> "r, g, b" between 0 and 1, as Plymouth wants it (same as image/lb/inside.sh)
rgb(){ local h=${1#\#}
       awk -v h="$h" 'BEGIN{ for(i=0;i<3;i++){ x=substr(h,i*2+1,2); v=0; for(j=1;j<=2;j++){ c=index("0123456789abcdef", tolower(substr(x,j,1)))-1; v=v*16+c }; printf "%s%.3f", (i?", ":""), v/255 } }'; }

sync(){
  local m=$1 h f src from what lim sig
  h=$(hostname); mkdir -p "$BR"; : > "$BR/source.new"
  for f in logo splash; do
    src=""; from=image
    if [ -f "$m/config/branding/$h/$f.png" ]; then src=$m/config/branding/$h/$f.png; from=device
    elif [ -f "$m/config/branding/$f.png" ]; then src=$m/config/branding/$f.png; from=common; fi
    if [ $f = logo ]; then what="logo"; lim="400 240"; else what="background picture"; lim="1024 640"; fi
    if [ -n "$src" ]; then
      if ! png_ok "$src" $lim; then
        # reported once per file: the previous image stays
        sig="$f $(stat -c '%s %Y' "$src")"
        grep -qxF "$sig" "$BR/rejected" 2>/dev/null || { echo "$sig" >> "$BR/rejected"; ev "$what of the management folder REJECTED ($from): not a PNG, or over 2 MB or ${lim/ /x} pixels"; }
        grep "^$f=" "$BR/source" 2>/dev/null >> "$BR/source.new"; continue
      fi
      if ! cmp -s "$src" "$BR/$f.png"; then
        cp "$src" "$BR/$f.png.new" && chmod 644 "$BR/$f.png.new" && mv -f "$BR/$f.png.new" "$BR/$f.png" &&
          ev "$what from the management folder ($from)"
      fi
    elif [ -f "$BR/$f.png" ]; then
      rm -f "$BR/$f.png"; ev "$what removed from the management folder: back to the image's own"
    fi
    echo "$f=$from" >> "$BR/source.new"
  done
  mv -f "$BR/source.new" "$BR/source"
}

# colors of the image: site.conf, then the defaults (not the device settings nor the central ones)
img_cfg(){ local f
  for f in "$OTR_SITE" "$OTR_DEFAULTS"; do
    [ -f "$f" ] && grep -q "^$1=" "$f" && { sed -n "s/^$1=//p" "$f" | head -1 | tr -d '\r'; return; }
  done; }
IMG_SPLASH=$OTR/branding/splash.png
# what the boot splash should show: picture + colors of the image, as one fingerprint
splash_want(){ { cat "$IMG_SPLASH"; echo "$(rgb "$(img_cfg BG_TOP)")|$(rgb "$(img_cfg BG_BOTTOM)")"; } | sha256sum | cut -c1-64; }
# what the theme in the system shows now
splash_have(){ { cat "$THEME/logo.png"; echo "$(sed -n 's/^Window.SetBackgroundTopColor(\(.*\));.*/\1/p' "$THEME/openthinrdp.script")|$(sed -n 's/^Window.SetBackgroundBottomColor(\(.*\));.*/\1/p' "$THEME/openthinrdp.script")"; } | sha256sum | cut -c1-64; }

splash(){
  # the live system has no initramfs of its own to rebuild
  otr_installed && [ -f "$THEME/openthinrdp.script" ] || return 0
  # first run: what the theme shows is in the initramfs already (image or previous version)
  [ -f "$BR/splash-applied" ] || { mkdir -p "$BR"; splash_have > "$BR/splash-applied"; }
  [ "$(splash_want)" = "$(cat "$BR/splash-applied")" ] && return 0
  systemctl is-active -q openthinrdp-splash 2>/dev/null && return 0
  systemd-run -q --unit=openthinrdp-splash --nice=10 "$OTR/branding.sh" splash-now >/dev/null 2>&1
}

splash_now(){
  local want; want=$(splash_want)
  cp "$IMG_SPLASH" "$THEME/logo.png"
  sed -i -e "s/^Window.SetBackgroundTopColor(.*);/Window.SetBackgroundTopColor($(rgb "$(img_cfg BG_TOP)"));/" \
         -e "s/^Window.SetBackgroundBottomColor(.*);/Window.SetBackgroundBottomColor($(rgb "$(img_cfg BG_BOTTOM)"));/" "$THEME/openthinrdp.script"
  # never at the same time as the rebuild of the first boot (boot.sh)
  if flock -w 900 /run/openthinrdp-initramfs.lock update-initramfs -u >/dev/null 2>&1; then
    echo "$want" > "$BR/splash-applied"; ev "boot splash: the image's own again (shown from the next restart)"
  else ev "boot splash: update of the initramfs FAILED, retried at the next report"; fi
}

case "$1" in
  sync) [ -d "$2" ] && sync "$2" ;;
  splash) splash ;;
  splash-now) splash_now ;;
  *) echo "usage: $0 sync <folder> | splash" >&2; exit 2 ;;
esac
exit 0
