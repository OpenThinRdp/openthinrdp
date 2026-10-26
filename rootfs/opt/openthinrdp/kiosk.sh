#!/bin/bash
# OpenThinRDP kiosk: login form, RDP session through the broker, reconnection, settings dialog.
# Runs as the kiosk user inside the X session (started by Openbox, see /etc/xdg/openbox/autostart).
. /opt/openthinrdp/lib/common.sh
. /opt/openthinrdp/lib/usb.sh
otr_lang
export DISPLAY=${DISPLAY:-:0}
for i in $(seq 1 200); do xset q >/dev/null 2>&1 && break; sleep 0.1; done

# Background: the boot splash is always the image's own; from here on the background picture of the site
# (management folder, otherwise the image's). Plymouth quits leaving its picture until X draws: no black gap.
background(){ command -v hsetroot >/dev/null && hsetroot -add "$(cfg BG_TOP)" -add "$(cfg BG_BOTTOM)" -gradient 0 -center "$SPLASH" 2>/dev/null; }
# title, logo and background, read again before every form: a logo or background picture of the management folder
# (branding.sh) and new colors show up without restarting the kiosk
LOOK=""
look(){
  local now
  TITLE=$(cfg TITLE); LOGO=$(otr_logo); IMG=""; [ -f "$LOGO" ] && IMG="--image=$LOGO"
  SPLASH=$(otr_splash)
  now="$SPLASH $(stat -c %Y "$SPLASH" 2>/dev/null) $(cfg BG_TOP) $(cfg BG_BOTTOM)"
  [ "$now" = "$LOOK" ] || { LOOK=$now; background; }
}
look
sudo -n /usr/bin/plymouth quit --retain-splash 2>/dev/null
xset s off -dpms s noblank 2>/dev/null
numlockx on 2>/dev/null            # FreeRDP sends the NumLock state to Windows when connecting
# The X authorization is tied to the hostname: after renaming the device from the settings dialog no new
# window would open any more (every dialog failed as if "Shut down" had been pressed).
xhost +si:localuser:"$(id -un)" >/dev/null 2>&1
ev "kiosk started"

# Screen always on. A monitor that powers on or wakes up AFTER X (slow HDMI, monitor off at boot) leaves X
# without outputs and the screen black for good: every 2 s check that each connected monitor has a picture,
# otherwise enable it and redraw background and login form.
monitor_watch(){
  while sleep 2; do
    # --current does not probe the monitor (no flicker); "connected (" = connected but no picture
    if xrandr --current 2>/dev/null | grep -qE ' connected (primary )?\('; then
      ev "monitor connected without picture: enabled"
      xrandr --auto 2>/dev/null; sleep 1
      xset s off -dpms s noblank 2>/dev/null
      SPLASH=$(otr_splash); background
      # the form was drawn for the wrong resolution: close it, the main loop draws it again
      pgrep -x xfreerdp3 >/dev/null || pkill -f -- '--class=OtrLogin' 2>/dev/null
    fi
  done
}
monitor_watch &

# Software update installing: a small notice in the top right corner while it lasts, so nobody switches the device
# off in the middle (the Shut down button waits for it anyway). Not during a remote session: it would cover it.
update_watch(){
  local y="" w UIOK=0 bsig nsig
  bsig=$(stat -c %Y "$OTR_LIB"/branding/*.png 2>/dev/null | tr '\n' ' ')
  python3 -c 'import gi; gi.require_version("Gtk", "3.0")' 2>/dev/null && UIOK=1
  while sleep 5; do
    # a new logo or background picture of the management folder, new settings (central-apply.sh writes them only
    # when something changes: a default user that came after the form was drawn), or a new version offered to a
    # device without a management folder (update_question asks before the form): the sign-in screen again (not in a
    # session)
    nsig=$(stat -c %Y "$OTR_LIB"/branding/*.png "$OTR_CONF" /run/openthinrdp-update-offer 2>/dev/null | tr '\n' ' ')
    if [ "$nsig" != "$bsig" ]; then bsig=$nsig; pgrep -x xfreerdp3 >/dev/null || pkill -f -- "--class=OtrLogin" 2>/dev/null; fi
    # not while the full screen power-off notice shows the same progress
    if updating && ! pgrep -x xfreerdp3 >/dev/null && [ ! -f /tmp/openthinrdp-poweroff-pending ]; then
      if [ -z "$y" ] || ! kill -0 "$y" 2>/dev/null; then
        if [ $UIOK = 1 ]; then python3 "$OTR/ui.py" toast --text="$L_UPDATE_RUNNING (%p%)" 2>/dev/null & y=$!
        else
          w=$(xrandr --current 2>/dev/null | sed -n 's/.*current \([0-9]*\) x.*/\1/p' | head -1)
          yad --undecorated --skip-taskbar --on-top --no-focus --no-buttons --borders=10 --width=360 \
              --posx=$(( ${w:-1024} - 380 )) --posy=20 --text="⟳  $L_UPDATE_RUNNING" 2>/dev/null & y=$!
        fi
      fi
    elif [ -n "$y" ]; then kill "$y" 2>/dev/null; y=""; fi
  done
}
update_watch &

# Pointer on the kiosk screens: hidden while the mouse is still, back as soon as it moves (unclutter-xfixes). Not in
# the remote desktop, where Windows draws its own pointer: stopped as soon as the desktop window is on screen.
pointer_idle_hide(){
  command -v unclutter >/dev/null || return 0
  pgrep -u "$(id -u)" -x unclutter >/dev/null || { unclutter --timeout 2 --jitter 3 --start-hidden --hide-on-touch >/dev/null 2>&1 & }
}
pointer_show(){ pkill -u "$(id -u)" -x unclutter 2>/dev/null; return 0; }
pointer_idle_hide

DEF=$(cfg DEFAULT_USER)

# Webcams and USB sound devices (headsets, speakerphones, the microphone of a webcam). Passed whole over USB they
# reach the VM as devices of the console session, and Windows does not offer their microphone to the apps of the
# remote session: the session sees no microphone and a meeting has picture but no sound. So the thin client keeps
# them: sound goes through the RDP audio channels and, with a FreeRDP that captures through the camera channel
# ([MS-RDPECAM] with Video4Linux, as Debian builds it), the picture through that channel (/dvc:rdpecam). Without it
# a webcam is still passed whole, for the picture. --buildconfig does not list channels: the client library is
# looked at instead.
HASCAM=0
_L=$(ldd "$(command -v xfreerdp3)" 2>/dev/null | sed -n 's/.*libfreerdp-client3[^ ]* => \([^ ]*\).*/\1/p')
[ -n "$_L" ] && grep -aq v4l_freerdp_rdpecam_client_subsystem_entry "$_L" && HASCAM=1
# The largest resolution of the webcam offered to Windows (CAMERA_MAX): an app picks the largest it is offered, a 2K
# webcam more than a small processor reads and encodes in time. auto = 1080p when the video engine of the processor
# encodes H.264 (VA-API) and CAMERA_HWACCEL is on, else 720p.
cam_maxres(){
  case "$(cfg CAMERA_MAX)" in 720p) echo 1280x720 ;; 1080p) echo 1920x1080 ;; max) echo 0 ;;
    *) if [ "$(cfg CAMERA_HWACCEL)" = on ] && vainfo --display drm 2>/dev/null | grep -q 'H264.*EncSlice'; then echo 1920x1080; else echo 1280x720; fi ;;
  esac
}
CAMID=""
if [ $HASCAM = 0 ]; then
  _V=$(udevadm info -q property -n /dev/video0 2>/dev/null | sed -n 's/^ID_VENDOR_ID=//p')
  _P=$(udevadm info -q property -n /dev/video0 2>/dev/null | sed -n 's/^ID_MODEL_ID=//p')
  [ -n "$_V" ] && [ -n "$_P" ] && CAMID="$_V:$_P"
fi

# Touch screens (VID:PID) stay on the thin client and the touches go to Windows through the RDP touch channel
# (+multitouch). Passed whole over USB a touch screen reaches the VM as a raw device that is not tied to the
# session screen and does not work. Sources: $OTR_LIB/touch-usb (written by udev when the touch screen
# appears, so it counts even while unplugged) + the input devices the kernel marks as direct (INPUT_PROP_DIRECT).
touch_ids(){
  local i p d
  { cat "$OTR_LIB/touch-usb" 2>/dev/null
    for i in /sys/class/input/input*; do
      p=$(cat "$i/properties" 2>/dev/null); [ -n "$p" ] && (( 0x$p & 2 )) || continue
      d=$(readlink -f "$i/device"); while [ -n "$d" ] && [ "$d" != / ]; do
        [ -f "$d/idVendor" ] && { echo "$(cat "$d/idVendor"):$(cat "$d/idProduct")"; break; }; d=$(dirname "$d"); done
    done; } | tr 'A-F' 'a-f' | grep -E '^[0-9a-f]{4}:[0-9a-f]{4}$' | sort -u
}
# Every connected USB device except keyboards and mice (HID boot protocol 1/2), hubs, Bluetooth, smart card
# readers, touch screens, network adapters, sound devices and, with the camera channel, webcams (see HASCAM).
# With USB_MODE=auto also the devices that are only storage: they stay here as drives (lib/usb.sh)
usb_all_ids(){
  local d i skip dp n audio video touch=" $(touch_ids | tr '\n' ' ') " auto=0
  local loc=" $(cfg USB_LOCAL | tr 'A-F' 'a-f') "
  [ "$(cfg USB_MODE)" = auto ] && auto=1
  for d in "$USB_SYS"/[0-9]*-[0-9]*; do
    [ -f "$d/idVendor" ] || continue
    [ "$(cat "$d/bDeviceClass" 2>/dev/null)" = 09 ] && continue
    skip=0; audio=0; video=0
    for i in "$d"/*:*; do
      [ -f "$i/bInterfaceClass" ] || continue
      case "$(cat "$i/bInterfaceClass")" in
        09|e0|0b) skip=1 ;;     # hub, Bluetooth, smart card reader (goes with /smartcard through pcscd)
        03) case "$(cat "$i/bInterfaceProtocol")" in 01|02) skip=1 ;; esac ;;
        01) audio=1 ;;
        0e) video=1 ;;
      esac
    done
    [ $video = 1 ] && [ $HASCAM = 1 ] && skip=1
    [ $audio = 1 ] && [ $video = 0 ] && skip=1
    # USB network adapter: given to Windows, the thin client would lose its network and the session
    dp=$(readlink -f "$d")
    for n in /sys/class/net/*/device; do case "$(readlink -f "$n")" in "$dp"/*) skip=1 ;; esac; done
    case "$touch" in *" $(cat "$d/idVendor"):$(cat "$d/idProduct") "*) skip=1 ;; esac
    # service controller of the hubs built into some monitors (Microchip USB27xx): useless to Windows,
    # it stays with a driver error in Device Manager
    [ "$(cat "$d/product" 2>/dev/null)" = "Hub Controller" ] && skip=1
    [ $auto = 1 ] && usb_storage_only "$d" && skip=1
    # kept here by USB_LOCAL: a stick seen as a drive also in the "all" mode
    case "$loc" in *" $(cat "$d/idVendor"):$(cat "$d/idProduct") "*) skip=1 ;; esac
    [ $skip = 0 ] && echo "$(cat "$d/idVendor"):$(cat "$d/idProduct")"
  done | sort -u | tr '\n' ' '
}
# FreeRDP with the filter: option (upstream since 3.33): devices plugged in during the session follow the same
# rules, HID, hubs, smart card readers, Bluetooth and sound devices stay here (with the camera channel webcams
# too), storage goes to Windows. A class matches the device or any of its interfaces.
USBFILTER=""
if xfreerdp3 /help 2>/dev/null | grep -q 'filter:<class>'; then
  USBFILTER=",filter:03#09#0b#e0#01"; [ $HASCAM = 1 ] && USBFILTER="$USBFILTER#0e"
fi
usb_opt(){
  local ids="$CAMID $(cfg USB_REDIRECT)" l="" i x scard loc=" $(cfg USB_LOCAL | tr 'A-F' 'a-f') "
  [ "$(cfg USB_MODE)" != disks ] && ids="$ids $(usb_all_ids)"
  # smart card readers never go as whole devices, even when listed in USB_REDIRECT (pcscd owns them); nor the disk
  # the system runs from (a Raspberry Pi booting from USB, the live system on a stick)
  scard=" $(for x in /sys/bus/usb/devices/*:*; do [ "$(cat "$x/bInterfaceClass" 2>/dev/null)" = 0b ] && echo "$(cat "${x%:*}/idVendor"):$(cat "${x%:*}/idProduct")"; done | sort -u | tr '\n' ' ') $(usb_system_ids | tr '\n' ' ') "
  for i in $(echo $ids | tr ' ' '\n' | tr 'A-F' 'a-f' | sort -u); do
    [[ $i =~ ^[0-9a-f]{4}:[0-9a-f]{4}$ ]] && [[ "$scard" != *" $i "* ]] && [[ "$loc" != *" $i "* ]] && l="$l${l:+#}$i"
  done
  # auto = a device that disconnects and comes back (keys that restart in another mode once they see a PC) is
  # passed again instead of being lost. The channel is always open, also without devices at login.
  # USB_MODE=disks: storage (class 08) stays here too, also when plugged in during the session: usb-mount.sh
  # mounts it and /drive:hotplug shows it in Windows. Without it FreeRDP took the stick whole (measured 13/10/2026).
  # USB_MODE=auto: the same for devices plugged in during the session. FreeRDP's filter matches a class on any
  # interface, so a device with storage and something else plugged in then stays here too, its storage as a drive;
  # connected at sign-in it goes whole (usb_all_ids)
  local f=$USBFILTER; [ -n "$f" ] && case "$(cfg USB_MODE)" in disks|auto) f="$f#08" ;; esac
  echo "/usb:auto${l:+,id:$l}$f"
}
# ALSA card of a USB sound device kept on the thin client (see HASCAM): $1 = c for a microphone, p for a speaker,
# $2 = the /usb option (a device listed there is passed whole and FreeRDP holds it). Prints the card id.
usb_sound_card(){
  local ids=" $(echo "$2" | sed -n 's/.*,id:\([^,]*\).*/\1/p' | tr '#' ' ') " c u
  for c in /proc/asound/card[0-9]*; do
    u=$(cat "$c/usbid" 2>/dev/null); [ -n "$u" ] || continue
    case "$ids" in *" $u "*) continue ;; esac
    compgen -G "$c/pcm*$1" >/dev/null && { cat "$c/id"; return 0; }
  done
  return 1
}
# Webcams and USB sound devices kept on the thin client (see HASCAM) but left without their Linux driver: taken
# whole by an earlier session, or by an older kiosk that passed them over USB, they come back unbound and the
# session would have no camera and no USB microphone. The kernel is asked to attach its driver to those interfaces
# again (USBDEVFS_CONNECT, what libusb_attach_kernel_driver does; a USB reset does not, it only re-attaches the
# drivers an interface had). An interface already taken by the driver of another one answers "busy". Never during
# a session, once per device while the kiosk runs (connect runs in a subshell: the devices done are kept in a file).
RECLAIMED=/tmp/kiosk.reclaimed; : > "$RECLAIMED"
usb_reclaim(){
  pgrep -x xfreerdp3 >/dev/null && return 0
  local d i c drv ifs id n done=0
  for d in /sys/bus/usb/devices/[0-9]*-[0-9]*; do
    [ -f "$d/busnum" ] || continue
    ifs=""
    for i in "$d"/*:*; do
      c=$(cat "$i/bInterfaceClass" 2>/dev/null) || continue
      case "$c" in 01) ;; 0e) [ $HASCAM = 1 ] || continue ;; *) continue ;; esac
      drv=$(basename "$(readlink "$i/driver" 2>/dev/null)" 2>/dev/null)
      { [ -z "$drv" ] || [ "$drv" = usbfs ]; } && ifs="$ifs $(cat "$i/bInterfaceNumber")"
    done
    id="$(cat "$d/idVendor"):$(cat "$d/idProduct")"
    [ -n "$ifs" ] && ! grep -qx "$id" "$RECLAIMED" 2>/dev/null || continue
    echo "$id" >> "$RECLAIMED"
    n=$(printf '/dev/bus/usb/%03d/%03d' "$(cat "$d/busnum")" "$(cat "$d/devnum")")
    # struct usbdevfs_ioctl { int ifno; int ioctl_code; void *data; } with USBDEVFS_CONNECT, through USBDEVFS_IOCTL
    python3 - "$n" $ifs <<'PY' 2>/dev/null && { ev "USB: $(cat "$d/product" 2>/dev/null) ($id) given back to the thin client"; done=1; }
import errno, fcntl, struct, sys
f = open(sys.argv[1], 'wb')
for n in sys.argv[2:]:
    try: fcntl.ioctl(f, 0xC0105512, struct.pack('iiQ', int(n, 16), 0x5517, 0))
    except OSError as e:
        if e.errno != errno.EBUSY: raise
PY
  done
  [ $done = 1 ] && sleep 2
  return 0
}
# USB reset of the webcam before connecting: some webcams are not re-enumerated reliably otherwise
reset_cam(){
  [ -z "$CAMID" ] && return
  local n pr
  for n in /dev/bus/usb/*/*; do
    pr=$(udevadm info -q property -n "$n" 2>/dev/null)
    if echo "$pr" | grep -qi "ID_VENDOR_ID=${CAMID%:*}" && echo "$pr" | grep -qi "ID_MODEL_ID=${CAMID#*:}"; then
      python3 -c "import fcntl,sys;fcntl.ioctl(open(sys.argv[1],'wb'),0x5514,0)" "$n" 2>/dev/null
      break
    fi
  done
}

# NTLM only: since FreeRDP 3.17 "ntlm,!kerberos" no longer excludes Kerberos, "none,ntlm" does (FreeRDP #11818).
# Kerberos only (RDP_AUTH=kerberos) the same way: the sign-in fails instead of falling back to NTLM
FRV=$(xfreerdp3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
NTLMPKG='ntlm,!kerberos'; KRBPKG='kerberos,!ntlm'
{ [ "${FRV%%.*}" -gt 3 ] || { [ "${FRV%%.*}" -eq 3 ] && [ "$(echo "$FRV" | cut -d. -f2)" -ge 17 ]; }; } 2>/dev/null && { NTLMPKG='none,ntlm'; KRBPKG='none,kerberos'; }
HASUDP=0; xfreerdp3 --buildconfig 2>/dev/null | grep -q 'WITH_RDPEUDP=ON' && HASUDP=1

# connect USER PASSWORD BROKER: one xfreerdp3 run; its exit code is the result
connect(){
  usb_reclaim; reset_cam; sleep 1
  local srv=$3
  # Kerberos (negotiate) needs the server's own name, not a shared alias or an address: see krb_host
  if [ "$(cfg RDP_AUTH)" != ntlm ]; then srv=$(krb_host "$3"); [ "$srv" != "$3" ] && ev "broker $3: connecting to $srv (Kerberos)"; fi
  local -a o=(/v:"$srv" /u:"$1" /p:"$2") extra
  local v i=1 dev usb mic
  v=$(cfg DOMAIN); [ -n "$v" ] && o+=(/d:"$v")
  v=$(cfg LOAD_BALANCE_INFO); [ -n "$v" ] && o+=(/load-balance-info:"$v")
  case "$(cfg RDP_AUTH)" in ntlm) o+=(/auth-pkg-list:"$NTLMPKG") ;; kerberos) o+=(/auth-pkg-list:"$KRBPKG") ;; esac
  case "$(cfg RDP_CERT)" in ignore) o+=(/cert:ignore) ;; verify) o+=(/cert:deny) ;; *) o+=(/cert:tofu) ;; esac
  v=$(cfg RDP_GFX); [ -n "$v" ] && o+=(/gfx:"$v")
  # auto and udp: the server measures the line (/network:auto) and lowers frame rate and quality when the
  # network or the server itself struggle. When UDP is blocked or fails FreeRDP goes on over TCP; with udp the
  # kiosk does not accept that (see session). No /auto-reconnect: when FreeRDP's own reconnection fails it
  # exits with code 1, the same code as an administrator disconnect, and the kiosk would stop. The kiosk
  # reopens the session instead, and every new connection tries UDP again.
  # tcp with a UDP-capable FreeRDP needs -multitransport.
  # /timeout: FreeRDP's TcpAckTimeout, 9 s by default, bounds two things: how long the connection may take to
  # become active (a broker preparing a virtual machine took 15 s, and the client gave up at 9 s) and how long the
  # TCP connection beside the UDP tunnel may go unacknowledged (on a line losing 60-70% of the packets the TCP
  # connection was given up at 9 s while the UDP tunnel still carried the session). 20 s and no more: a broker
  # that accepts the connection and then hangs costs this much on every attempt before the next one.
  o+=(/timeout:20000)
  # RD Gateway: the broker and the VM through it, over HTTPS, with the credentials of the session (FreeRDP's
  # default). FreeRDP carries no UDP through a gateway: with always no UDP is offered at all (-multitransport); with
  # detect FreeRDP declines it by itself when the connection goes through the gateway, and keeps it when the server
  # is reached straight (FreeRDP dda5414; the earlier one declined it as soon as a gateway was set).
  # /network:auto stays: the server adapts frame rate and quality to the line, which matters most from outside.
  v=$(cfg RDP_GATEWAY)
  if [ -n "$v" ]; then
    if [ "$(cfg RDP_GATEWAY_USE)" = detect ]; then o+=(/gateway:g:"$v",type:auto,usage-method:detect)
    else o+=(/gateway:g:"$v",type:auto,usage-method:direct /network:auto -multitransport); fi
  fi
  if [ -n "$v" ] && [ "$(cfg RDP_GATEWAY_USE)" != detect ]; then :
  # auto after the UDP transport stalled in this run (watchdog 3, /tmp/kiosk.udpstall): TCP until the device restarts
  elif [ $HASUDP = 1 ] && [ "$(cfg TRANSPORT)" != tcp ] && { [ "$(cfg TRANSPORT)" = udp ] || [ ! -f /tmp/kiosk.udpstall ]; }; then o+=(/network:auto)
  elif [ $HASUDP = 1 ]; then o+=(/network:lan -multitransport)
  else o+=(/network:lan); fi
  v=$(cfg RDP_KEYBOARD); [ -n "$v" ] && o+=(/kbd:layout:"$v")
  # every monitor when more than one is connected (with /f the session is full screen on all of them)
  [ "$(cfg MULTIMON)" != off ] && [ "$(xrandr --current 2>/dev/null | grep -c ' connected')" -gt 1 ] && o+=(/multimon)
  for dev in /dev/ttyUSB* /dev/ttyACM* /dev/ttyS0; do [ -e "$dev" ] && { o+=(/serial:"COM$i,$dev"); i=$((i+1)); }; done
  usb=$(usb_opt); o+=("$usb")
  [ -n "$(touch_ids)" ] && o+=(+multitouch)
  # microphone and speaker: those of a USB headset, speakerphone or webcam when there is one, else the built-in
  # ones (see HASCAM); plughw converts to the rate and channels the session asks for
  local snd=/sound:sys:alsa card
  if card=$(usb_sound_card c "$usb"); then o+=(/microphone:sys:alsa,dev:plughw:CARD="$card"); ev "microphone: USB ($card)"
  else o+=(/microphone:sys:alsa); fi
  card=$(usb_sound_card p "$usb") && snd=/sound:sys:alsa,dev:plughw:CARD="$card"
  # the camera channel with its options (CAMERA_H264, CAMERA_HWACCEL, CAMERA_MAX): a FreeRDP without them ignores them
  [ $HASCAM = 1 ] && o+=(/dvc:rdpecam,h264:$(cfg CAMERA_H264),hwaccel:$(cfg CAMERA_HWACCEL),maxres:$(cam_maxres))
  read -ra extra <<< "$(cfg RDP_EXTRA)"
  # the USB devices passed whole wait for the desktop (usb-hold.sh): a device that hangs while Windows starts it
  # must not hold up the session's display. The progress loop releases them 15 s after the window is up.
  local held; held=$(echo "$usb" | sed -n 's/.*,id:\([^,]*\).*/\1/p' | tr '#' ' ')
  [ -n "$held" ] && sudo -n "$OTR/usb-hold.sh" hold $held >/dev/null 2>&1
  # setsid, input from /dev/null: no console for FreeRDP. Missing a user or a password it would ask for them on tty1,
  # where nobody can answer: stopped by the kernel (SIGTTOU), the screen stuck on "connecting" until switched off.
  # Without a console the question fails at once and the attempt ends with its error.
  setsid -w xfreerdp3 "${o[@]}" /gdi:hw /bpp:32 /dynamic-resolution /f /smartcard /drive:hotplug,'*' \
    "$snd" /clipboard "${extra[@]}" < /dev/null > /tmp/kiosk.log 2>&1
}

# --- settings dialog ----------------------------------------------------------------------------
# prefix /23 -> 255.255.254.0
pfx2mask(){ local p=$1 m="" i o; for i in 1 2 3 4; do if [ $p -ge 8 ]; then o=255; p=$((p-8)); else o=$(( 256 - (1 << (8-p)) )); [ $p -eq 0 ] && o=0; p=0; fi; m="$m${m:+.}$o"; done; echo $m; }
# combo VALUE VALUES_ARRAY LABELS_ARRAY: yad list "a!^b!c" with the label of VALUE selected
combo(){ local cur=$1 i out=""; local -n vs=$2 ls=$3
  for i in "${!vs[@]}"; do out+="${out:+!}$([ "${vs[$i]}" = "$cur" ] && echo '^')${ls[$i]}"; done; echo "$out"; }
# unlabel LABEL VALUES_ARRAY LABELS_ARRAY: the value behind a label chosen in a combo
unlabel(){ local lab=$1 i; local -n vs=$2 ls=$3
  for i in "${!ls[@]}"; do [ "${ls[$i]}" = "$lab" ] && { echo "${vs[$i]}"; return; }; done; echo "${vs[0]}"; }
# the settings can be protected by a PIN (SETTINGS_PIN_SHA256): anyone at the device could change the broker.
# The value is pbkdf2-sha256:<iterations>:<salt>:<key> (salted and slow: a short PIN is not reversed in seconds
# by whoever gets the settings file) or, as set by 0.1.4 and earlier, the plain SHA-256 of the PIN.
pin_match(){ # PIN on stdin, stored value in $1
  case "$1" in
    pbkdf2-sha256:*) python3 -c 'import hashlib, hmac, sys
_, it, salt, key = sys.argv[1].split(":")
d = hashlib.pbkdf2_hmac("sha256", sys.stdin.read().encode(), bytes.fromhex(salt), int(it)).hex()
sys.exit(0 if hmac.compare_digest(d, key) else 1)' "$1" 2>/dev/null ;;
    *) [ "$(sha256sum | cut -c1-64)" = "$1" ] ;;
  esac
}
pin_ok(){
  local h p r=99; h=$(cfg SETTINGS_PIN_SHA256); [ -z "$h" ] && return 0
  # typed less than 2 minutes ago (from the settings to the Wi-Fi page and back): not asked again
  [ "${PIN_UNTIL:-0}" -gt "$(date +%s)" ] && return 0
  if [ $GREETER = 1 ]; then
    p=$(ui pin --heading="$(plain "$L_PIN_ASK")" --t-save="$L_OK" --t-close="$L_CANCEL"); r=$?
    [ $r = 11 ] && return 1
  fi
  # the yad dialog when the screen of ui.py did not work: the settings must always be reachable.
  # Enter in the entry field presses the LAST button: OK goes last
  if [ $r != 0 ]; then
    p=$(yad --entry --hide-text $IMG --title="$TITLE" --center --text="$L_PIN_ASK" --button="$L_CANCEL:1" --button="$L_OK:0" 2>/dev/null) || return 1
  fi
  printf "%s" "$p" | pin_match "$h" && { PIN_UNTIL=$(( $(date +%s) + 120 )); return 0; }
  ev "settings: wrong PIN"
  if [ $GREETER = 1 ]; then ui message --icon=error --heading="$(plain "$L_PIN_WRONG")" --timeout=3 >/dev/null
  else yad --error --center --timeout=3 --text="$L_PIN_WRONG" 2>/dev/null; fi
  return 1
}
# the settings screen of ui.py (form): sections, and per field KEY type label value choices hint (tab separated).
# Reads the values of settings_dialog (bash: the caller's locals are visible here)
settings_spec(){
  local t=$'\t'
  sec(){ printf 'S\t%s\n' "$1"; }
  fld(){ printf 'F\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4//$t/ }" "$5" "$6"; }
  chs(){ local -n vs=$1 ls=$2; local i o=""; for i in "${!vs[@]}"; do o+="${o:+|}${vs[$i]}=${ls[$i]}"; done; printf '%s' "$o"; }
  sec "$L_SEC_REMOTE"
  fld HOSTNAME text "$L_F_HOSTNAME" "$h" "" "$L_H_HOSTNAME"
  fld DEFAULT_USER text "$L_F_USER" "$u" "" "$L_H_USER"
  fld BROKER text "$L_F_BROKER" "$br" "" "$L_H_BROKER"
  fld BROKER_FALLBACK text "$L_F_FALLBACK" "$brf" "" "$L_H_FALLBACK"
  fld DOMAIN text "$L_F_DOMAIN" "$dom" "" "$L_H_DOMAIN"
  fld LOAD_BALANCE_INFO text "$L_F_COLLECTION" "$lbi" "" "$L_H_COLLECTION"
  fld TRANSPORT choice "$L_F_TRANSPORT" "$tr" "$(chs TRV TRL)" "$L_H_TRANSPORT"
  fld SESSION_THRESHOLD text "$L_F_THRESHOLD" "$thr" "" "$L_H_THRESHOLD"
  fld SHUTDOWN_SECS text "$L_F_SHUTDOWN" "$off" "" "$L_H_SHUTDOWN"
  sec "$L_SEC_NETWORK"
  fld NETMODE choice "$L_F_NETWORK" "$nm" "$(chs NETV NETL)" "$L_H_NETWORK"
  fld IPADDR text "$L_F_IP" "$ip" "" "$L_H_IP"
  fld NETMASK text "$L_F_NETMASK" "$mask" "" "$L_H_NETMASK"
  fld GATEWAY text "$L_F_GATEWAY" "$gw" "" "$L_H_GATEWAY"
  fld DNS1 text "$L_F_DNS1" "$d1" "" "$L_H_DNS1"
  fld DNS2 text "$L_F_DNS2" "$d2" "" "$L_H_DNS2"
  fld NTP text "$L_F_NTP" "$ntp" "" "$L_H_NTP"
  fld TIMEZONE tz "$L_F_TZ" "$tz" "" "$L_H_TZ"
  sec "$L_SEC_WIFI"
  fld WIFI choice "$L_F_WIFI" "$wf" "$(chs ONV ONL)" "$L_H_WIFI"
  fld WIFI_SSID text "$L_F_SSID" "$ws" "" "$L_H_SSID"
  fld WIFI_SECURITY choice "$L_F_WIFISEC" "$wsec" "$(chs WSECV WSECL)" "$L_H_WIFISEC"
  fld WIFI_PSK password "$L_F_WIFIPSK" "" "" "$L_H_WIFIPSK"
  sec "$L_SEC_DOT1X"
  fld DOT1X_STATE ro "$L_F_STATUS" "$d1xs" "" ""
  fld DOT1X choice "$L_F_DOT1X" "$d1x" "$(chs D1XV D1XL)" "$L_H_DOT1X"
  fld EAP_IDENTITY text "$L_F_EAPID" "$eid" "" "$L_H_EAPID"
  fld EAP_ANONYMOUS text "$L_F_EAPANON" "$ean" "" "$L_H_EAPANON"
  fld EAP_PASSWORD password "$L_F_EAPPW" "" "" "$L_H_EAPPW"
  fld EAP_CA text "$L_F_EAPCA" "$eca" "" "$L_H_EAPCA"
  fld EAP_SERVER_NAME text "$L_F_EAPSERVER" "$esn" "" "$L_H_EAPSERVER"
  sec "$L_SEC_USB"
  fld USB_MODE choice "$L_F_USBMODE" "$um" "$(chs USBV USBL)" "$L_H_USBMODE"
  fld USB_REDIRECT text "$L_F_USBLIST" "$ur" "" "$L_H_USBLIST"
  fld USB_LOCAL text "$L_F_USBLOCAL" "$ul" "" "$L_H_USBLOCAL"
  sec "$L_SEC_WEB"
  fld WEB_BUTTON choice "$L_F_WEB" "$wb" "$(chs WEBV WEBL)" "$L_H_WEB"
  fld WEB_URL text "$L_F_WEBURL" "$wu" "" "$L_H_WEBURL"
  fld KIOSK_URL text "$L_F_KIOSKURL" "$ku" "" "$L_H_KIOSKURL"
  fld KIOSK_RELOAD_MIN text "$L_F_RELOAD" "$kr" "" "$L_H_RELOAD"
  sec "$L_SEC_POWER"
  fld POWER_ON_TIME text "$L_F_POWERON" "$pon" "" "$L_H_POWERON"
  fld POWER_OFF_TIME text "$L_F_POWEROFF" "$poff" "" "$L_H_POWEROFF"
  fld POWER_ON_DAYS text "$L_F_DAYS" "$pdays" "" "$L_H_DAYS"
  sec "$L_SEC_MGMT"
  fld MGMT_SHARE text "$L_F_SHARE" "$share" "" "$L_H_SHARE"
  fld MGMT_USER text "$L_F_MGMTUSER" "$mu" "" "$L_H_MGMTUSER"
  fld MGMT_PASSWORD password "$L_F_MGMTPW" "" "" "$L_H_MGMTPW"
  fld SECURITY_UPDATES choice "$L_F_UPDATES" "$su" "$(chs ONV ONL)" "$L_H_UPDATES"
  fld LANGUAGE choice "$L_F_LANGUAGE" "$ln" "$(chs LNV LNL)" "$L_H_LANGUAGE"
  fld ANON_STATS choice "$L_F_ANON" "$an" "$(chs ONV ONL)" "$L_H_ANON"
}
# KEY=value lines of the settings screen into the values of settings_dialog
settings_read(){
  local l v
  while IFS= read -r l; do
    v=${l#*=}
    case ${l%%=*} in
      HOSTNAME) h=$v ;; DEFAULT_USER) u=$v ;; BROKER) br=$v ;; BROKER_FALLBACK) brf=$v ;; DOMAIN) dom=$v ;;
      LOAD_BALANCE_INFO) lbi=$v ;; NETMODE) nm=$v ;; IPADDR) ip=$v ;; NETMASK) mask=$v ;; GATEWAY) gw=$v ;;
      DNS1) d1=$v ;; DNS2) d2=$v ;; NTP) ntp=$v ;; SHUTDOWN_SECS) off=$v ;; SESSION_THRESHOLD) thr=$v ;;
      TRANSPORT) tr=$v ;; LANGUAGE) ln=$v ;; MGMT_SHARE) share=$v ;; MGMT_USER) mu=$v ;; MGMT_PASSWORD) mp=$v ;;
      USB_MODE) um=$v ;; USB_REDIRECT) ur=$v ;; USB_LOCAL) ul=$v ;; SECURITY_UPDATES) su=$v ;; ANON_STATS) an=$v ;; TIMEZONE) tz=$v ;; WEB_BUTTON) wb=$v ;; WEB_URL) wu=$v ;;
      KIOSK_URL) ku=$v ;; KIOSK_RELOAD_MIN) kr=$v ;; POWER_ON_TIME) pon=$v ;; POWER_OFF_TIME) poff=$v ;;
      POWER_ON_DAYS) pdays=$v ;; WIFI) wf=$v ;; WIFI_SSID) ws=$v ;; WIFI_PSK) wp=$v ;;
      WIFI_SECURITY) wsec=$v ;; DOT1X) d1x=$v ;; EAP_IDENTITY) eid=$v ;; EAP_ANONYMOUS) ean=$v ;; EAP_PASSWORD) epw=$v ;;
      EAP_CA) eca=$v ;; EAP_SERVER_NAME) esn=$v ;;
    esac
  done <<< "$1"
}
# The Wi-Fi page (ui.py wifi, wifi.sh as root): the networks around, one chosen, its password, the result on the page.
# The network is tried before anything is saved: a wrong password leaves the Wi-Fi of before.
wifi_page(){
  [ $GREETER = 1 ] || return
  . "$OTR/lib/netif.sh"; [ -n "$(wifi_nics | head -1)" ] || { ui message --icon=warn --text="$(plain "$L_WP_NOWIFI")" --timeout=8 --button="$L_OK:0" --primary=0 --default=0; return; }
  printf '%s\t%s\n' heading "$L_WP_HEADING" status_wifi "$L_WP_ST_WIFI" status_wired "$L_WP_ST_WIRED" status_none "$L_WP_ST_NONE" \
    list "$L_WP_LIST" refresh "$L_WP_REFRESH" scanning "$L_WP_SCANNING" nonefound "$L_WP_NONEFOUND" choose "$L_WP_CHOOSE" \
    chosen "$L_WP_CHOSEN" password "$L_PASSWORD" show "$L_WP_SHOW" connect "$L_WP_CONNECT" close "$L_CLOSE" current "$L_WP_CURRENT" \
    sec_psk "$L_WP_SEC_PSK" sec_eap "$L_WP_SEC_EAP" sec_open "$L_WP_SEC_OPEN" sec_wep "$L_WP_SEC_WEP" \
    step_stop "$L_WP_STEP_STOP" step_test "$L_WP_STEP_TEST" step_save "$L_WP_STEP_SAVE" step_dhcp "$L_WP_STEP_DHCP" \
    ok "$L_WP_OK" noip "$L_WP_NOIP" wrongkey "$L_WP_WRONGKEY" notfound "$L_WP_NOTFOUND" timeout "$L_WP_TIMEOUT" \
    invalid "$L_WP_INVALID" nowifi "$L_WP_NOWIFI" busy "$L_WP_BUSY" saveerror "$L_WP_SAVEERROR" central "$L_WP_CENTRAL" \
    | ui wifi --heading="$(plain "$L_WP_HEADING")"
}

settings_dialog(){
  pin_ok || return
  local IF IPC PFX GWC mac sync st rep wli wst out r tmp msg
  . "$OTR/lib/netif.sh"; IF=$(main_nic)
  IPC=$(ip -4 -o addr show dev "$IF" 2>/dev/null | awk '{print $4}' | head -1); PFX=${IPC#*/}; IPC=${IPC%/*}
  GWC=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
  mac=$(cat "/sys/class/net/$IF/address" 2>/dev/null)
  [ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" = yes ] && sync=$L_TIME_SYNC || sync=$L_TIME_NOSYNC
  wli=$(wifi_nics | head -1)
  if [ -z "$wli" ]; then wst=$L_WIFI_NONE
  elif iw dev "$wli" link 2>/dev/null | grep -q Connected; then wst=$(printf "$L_WIFI_CONNECTED" "$(iw dev "$wli" link | sed -n 's/^[[:space:]]*SSID: //p') $(iw dev "$wli" link | sed -n 's/^[[:space:]]*signal: //p')")
  else wst=$L_WIFI_DISCONNECTED; fi
  rep=$(tail -1 "$OTR_LOG/report.log" 2>/dev/null | cut -c1-60)
  st=$(printf "$L_STATUS_LINE" "${IPC:-$L_NO_NETWORK}" "$mac" "$(date +%H:%M)" "$sync" "$wst" "${rep:-$L_NEVER}")

  local -a NETV=(dhcp static) NETL=("DHCP" "$L_STATIC") USBV=(auto all disks) USBL=("$L_USB_AUTO" "$L_USB_ALL" "$L_USB_DISKS")
  local -a ONV=(on off) ONL=("$L_ON" "$L_OFF") TRV=(auto udp tcp) TRL=("$L_TR_AUTO" "$L_TR_UDP" "$L_TR_TCP")
  local -a WEBV=(none app browser kiosk) WEBL=("$L_WEB_NONE" "$L_WEB_APP" "$L_WEB_BROWSER" "$L_WEB_KIOSK")
  local -a LNV=(en it) LNL=(English Italiano)
  local -a WSECV=(psk peap tls) WSECL=("$L_WSEC_PSK" "$L_WSEC_PEAP" "$L_WSEC_TLS") D1XV=(off peap tls) D1XL=("$L_OFF" "$L_D1X_PEAP" "$L_D1X_TLS")
  local h u br brf dom lbi nm ip mask gw d1 d2 ntp off thr share mu mp um ur su an tz tr wb wu ku kr pon poff pdays wf ws wp ln
  local wsec d1x d1xs eid ean epw eca esn
  wsec=$(cfg WIFI_SECURITY); d1x=$(cfg DOT1X); eid=$(cfg EAP_IDENTITY); ean=$(cfg EAP_ANONYMOUS); eca=$(cfg EAP_CA); esn=$(cfg EAP_SERVER_NAME)
  d1xs=$("$OTR/dot1x.sh" status 2>/dev/null)
  h=$(hostname); u=$(cfg DEFAULT_USER); br=$(cfg BROKER); brf=$(cfg BROKER_FALLBACK); dom=$(cfg DOMAIN); mu=$(cfg MGMT_USER)
  lbi=$(cfg LOAD_BALANCE_INFO); nm=$(cfg NETMODE)
  if [ "$nm" = static ]; then ip=$(cfg IPADDR); mask=$(cfg NETMASK); gw=$(cfg GATEWAY)
  else ip=$IPC; mask=$([ -n "$IPC" ] && pfx2mask "$PFX" || cfg NETMASK); gw=${GWC:-$(cfg GATEWAY)}; fi
  d1=$(cfg DNS1); d2=$(cfg DNS2); ntp=$(cfg NTP); off=$(cfg_num SHUTDOWN_SECS 10); thr=$(cfg_num SESSION_THRESHOLD 10)
  share=$(cfg MGMT_SHARE); um=$(cfg USB_MODE); ur=$(cfg USB_REDIRECT); ul=$(cfg USB_LOCAL); su=$(cfg SECURITY_UPDATES); an=$(cfg ANON_STATS); tz=$(cfg TIMEZONE); tr=$(cfg TRANSPORT)
  wb=$(cfg WEB_BUTTON); wu=$(cfg WEB_URL); ku=$(cfg KIOSK_URL); kr=$(cfg_num KIOSK_RELOAD_MIN 10)
  pon=$(cfg POWER_ON_TIME); poff=$(cfg POWER_OFF_TIME); pdays=$(cfg POWER_ON_DAYS); wf=$(cfg WIFI); ws=$(cfg WIFI_SSID); ln=$(cfg LANGUAGE)
  # two columns: on one column the dialog does not fit a 1440x900 screen and Save disappears. Below 900 px
  # (1366x768, 1280x1024 is fine but 1024x768 is not) even two columns are taller than the screen: the form
  # scrolls inside a window as high as the screen, so the buttons stay visible
  local sw sh; local -a geo=(--width=1150)
  read -r sw sh < <(xdpyinfo 2>/dev/null | awk '/dimensions:/{split($2, a, "x"); print a[1], a[2]; exit}')
  if [ -n "$sh" ] && { [ "$sh" -lt 900 ] || [ "$sw" -lt 1170 ]; }; then
    geo=(--scroll --width=$(( sw < 1170 ? sw - 20 : 1150 )) --height=$(( sh - 40 )))
  fi
  # fields separated by a character nobody can type (unit separator): passwords may contain anything else
  local FS=$'\x1f'
  while true; do
    r=99
    if [ $GREETER = 1 ]; then
      # a device with a Wi-Fi adapter: the Wi-Fi page from here (13), the settings again after it with what it saved
      local -a wbt=(); [ -n "$wli" ] && wbt=(--button="$L_WIFI_PAGE:13")
      out=$(settings_spec | ui form --heading="$(plain "$L_SETTINGS")" --small="$(plain "$st")" \
              --t-save="$L_SAVE" --t-close="$L_CLOSE" --t-terminal="$L_TERMINAL" "${wbt[@]}"); r=$?
      case $r in
        0) wp=""; mp=""; epw=""; settings_read "$out" ;;
        11) break ;;
        13) wifi_page; settings_dialog; return ;;
        12) xterm -fa Monospace -fs 11 2>/dev/null; break ;;
        *) ev "settings: the settings screen failed (exit $r), the earlier dialog instead" ;;
      esac
    fi
    if [ $r != 0 ]; then
    # the earlier yad dialog, when the screen of ui.py cannot open (the settings must always be reachable).
    # 34 fields, 17 per column: left the connection, the network and the session; right the management folder,
    # USB, web button, power schedule and Wi-Fi
    out=$(yad --form --title="$L_SETTINGS" --columns=2 "${geo[@]}" --center --separator="$FS" \
          --text="<b>$L_SETTINGS</b>\n<small>$L_SETTINGS_HELP</small>" \
          --field="$L_F_HOSTNAME" --field="$L_F_USER" --field="$L_F_BROKER" --field="$L_F_FALLBACK" \
          --field="$L_F_DOMAIN" --field="$L_F_COLLECTION" --field="$L_F_NETWORK:CB" --field="$L_F_IP" \
          --field="$L_F_NETMASK" --field="$L_F_GATEWAY" --field="$L_F_DNS1" --field="$L_F_DNS2" \
          --field="$L_F_NTP" --field="$L_F_SHUTDOWN" --field="$L_F_THRESHOLD" --field="$L_F_TRANSPORT:CB" \
          --field="$L_F_LANGUAGE:CB" \
          --field="$L_F_SHARE" --field="$L_F_MGMTUSER" --field="$L_F_MGMTPW:H" \
          --field="$L_F_USBMODE:CB" --field="$L_F_USBLIST" --field="$L_F_UPDATES:CB" \
          --field="$L_F_WEB:CB" --field="$L_F_WEBURL" --field="$L_F_KIOSKURL" --field="$L_F_RELOAD" \
          --field="$L_F_POWERON" --field="$L_F_POWEROFF" --field="$L_F_DAYS" \
          --field="$L_F_STATUS:RO" --field="$L_F_WIFI:CB" --field="$L_F_SSID" --field="$L_F_WIFIPSK:H" \
          --button="$L_TERMINAL:2" --button="$L_CLOSE:1" --button="$L_SAVE:0" \
          "$h" "$u" "$br" "$brf" "$dom" "$lbi" "$(combo "$nm" NETV NETL)" "$ip" "$mask" "$gw" "$d1" "$d2" \
          "$ntp" "$off" "$thr" "$(combo "$tr" TRV TRL)" "$(combo "$ln" LNV LNL)" \
          "$share" "$mu" "" "$(combo "$um" USBV USBL)" "$ur" "$(combo "$su" ONV ONL)" \
          "$(combo "$wb" WEBV WEBL)" "$wu" "$ku" "$kr" "$pon" "$poff" "$pdays" \
          "$st" "$(combo "$wf" ONV ONL)" "$ws" "" 2>/dev/null)
    r=$?
    [ $r -eq 2 ] && { xterm -fa Monospace -fs 11 2>/dev/null; return; }
    [ $r -ne 0 ] && return
    IFS=$FS read -r h u br brf dom lbi nm ip mask gw d1 d2 ntp off thr tr ln share mu mp um ur su wb wu ku kr pon poff pdays _ wf ws wp <<< "$out"
    # the last field keeps the separator yad writes after it
    wp=${wp%"$FS"}
    nm=$(unlabel "$nm" NETV NETL); um=$(unlabel "$um" USBV USBL); su=$(unlabel "$su" ONV ONL); tr=$(unlabel "$tr" TRV TRL)
    wb=$(unlabel "$wb" WEBV WEBL); ln=$(unlabel "$ln" LNV LNL); wf=$(unlabel "$wf" ONV ONL)
    fi
    tmp=$(mktemp)
    printf '%s\n' "HOSTNAME=$h" "DEFAULT_USER=$u" "BROKER=$br" "BROKER_FALLBACK=$brf" "DOMAIN=$dom" \
      "LOAD_BALANCE_INFO=$lbi" "NETMODE=$nm" "IPADDR=$ip" "NETMASK=$mask" "GATEWAY=$gw" "DNS1=$d1" "DNS2=$d2" \
      "NTP=$ntp" "SHUTDOWN_SECS=$off" "SESSION_THRESHOLD=$thr" "MGMT_SHARE=$share" "MGMT_USER=$mu" "USB_MODE=$um" \
      "USB_REDIRECT=$ur" "USB_LOCAL=$ul" "SECURITY_UPDATES=$su" "ANON_STATS=$an" "TIMEZONE=$tz" "TRANSPORT=$tr" "WEB_BUTTON=$wb" "WEB_URL=$wu" "KIOSK_URL=$ku" \
      "KIOSK_RELOAD_MIN=$kr" "POWER_ON_TIME=$pon" "POWER_OFF_TIME=$poff" "POWER_ON_DAYS=$pdays" "LANGUAGE=$ln" \
      "WIFI=$wf" "WIFI_SSID=$ws" "WIFI_SECURITY=$wsec" "DOT1X=$d1x" "EAP_IDENTITY=$eid" "EAP_ANONYMOUS=$ean" \
      "EAP_CA=$eca" "EAP_SERVER_NAME=$esn" > "$tmp"
    [ -n "$wp" ] && printf 'WIFI_PSK=%s\n' "$wp" >> "$tmp"
    [ -n "$mp" ] && printf 'MGMT_PASSWORD=%s\n' "$mp" >> "$tmp"
    [ -n "$epw" ] && printf 'EAP_PASSWORD=%s\n' "$epw" >> "$tmp"
    msg=$(sudo -n "$OTR/save-config.sh" "$tmp" 2>&1); r=$?
    rm -f "$tmp"
    if [ $r -eq 0 ]; then
      ev "settings saved from the dialog: hostname=$h user=$u network=$nm ip=$ip broker=$br"
      otr_lang     # the language may have changed
      if [ $GREETER = 1 ]; then ui message --icon=ok --heading="$(plain "$L_SAVED")" --timeout=2 >/dev/null
      else yad --center --undecorated --skip-taskbar --no-buttons --timeout=2 --width=300 --text="<b>$L_SAVED</b>" 2>/dev/null; fi
      break
    fi
    ev "settings rejected: $(echo "$msg" | tr '\n' ' ')"
    if [ $GREETER = 1 ]; then ui message --icon=error --heading="$(plain "$L_INVALID")" --text="$(plain "$msg")" --button="$L_FIX:0" --primary=0 >/dev/null
    else yad --error --center --width=420 --title="$L_INVALID" --text="$msg" --button="$L_FIX:0" 2>/dev/null; fi
  done
  look; DEF=$(cfg DEFAULT_USER)
}

# --- diagnostics (no PIN: nothing can be changed here) ------------------------------------------
# What the IT desk asks first on the phone: address, gateway, DNS, can the broker or PC be reached, time, the
# management folder, the last events. Read only, a few seconds at most (3 s per remote desktop host).
diag_port(){ timeout 3 bash -c "</dev/tcp/$1/$2" 2>/dev/null && echo "$L_DIAG_OK" || echo "$L_DIAG_FAIL"; }
diag_dialog(){
  local r=99
  if [ $GREETER = 1 ]; then
    diag_text | ui text --heading="$(plain "$L_DIAG")" --text="$(plain "$L_DIAG_TEXT")" --t-close="$L_CLOSE" --button="$L_TEST:20" --button="$L_DIAG_SEND:22"; r=${PIPESTATUS[1]}
    [ "$r" = 20 ] && { selftest_dialog; return; }
    [ "$r" = 22 ] && { diag_send; return; }
  fi
  # the earlier yad window when the screen of ui.py cannot open
  [ "$r" = 0 ] || diag_text | yad --text-info --wrap $IMG --title="$L_DIAG" --width=780 --height=540 --center --fontname="Monospace 10" \
          --text="$L_DIAG_TEXT" --button="$L_CLOSE:0" 2>/dev/null
}
# The whole diagnostics (diag-bundle.sh) for the administrator: in diag\ of the management folder at once (its event
# starts report.sh), or kept on the device when it has none
diag_send(){
  { echo 30; echo "# $L_DIAG_COLLECT"; sudo -n "$OTR/diag-bundle.sh" device >/dev/null 2>&1; echo 100; } \
    | ui message --progress --icon=busy --heading="$(plain "$L_DIAG")" --text="$(plain "$L_DIAG_COLLECT")"
  if [ -n "$(cfg MGMT_SHARE)" ] || [ -s "$OTR_LIB/share-from-domain" ]; then
    ui message --icon=info --heading="$(plain "$L_DIAG")" --text="$(plain "$L_DIAG_SENT")" --button="$L_CLOSE:0" --primary=0 >/dev/null
  else ui message --icon=info --heading="$(plain "$L_DIAG")" --text="$(plain "$L_DIAG_LOCAL")" --button="$L_CLOSE:0" --primary=0 >/dev/null; fi
}
# Hardware test (selftest.sh, as root): the report, and on request a hardware report on GitHub, filled in and
# opened in the browser; the person sends it with their own GitHub account, nothing leaves the device by itself.
selftest_dialog(){
  local f=/run/openthinrdp-selftest.md rc
  { echo 20; echo "# $L_TEST_RUN"; sudo -n "$OTR/selftest.sh" --save >/dev/null 2>&1; echo 100; } \
    | ui message --progress --icon=busy --heading="$(plain "$L_TEST")" --text="$(plain "$L_TEST_RUN")"
  [ -s $f ] || return 0
  ui text --heading="$(plain "$L_TEST")" --text="$(plain "$L_TEST_TEXT")" --t-close="$L_CLOSE" --button="$L_TEST_SEND:21" < $f; rc=$?
  [ "$rc" = 21 ] || return 0
  local t b
  t=$(printf 'Hardware report: %s %s' "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" "$(cat /sys/class/dmi/id/product_name 2>/dev/null)" \
      | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read().strip()))')
  b=$(head -c 6000 $f | python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.stdin.read()))')
  ev "hardware report opened on GitHub to be sent"
  "$OTR/browser.sh" kiosk "https://github.com/OpenThinRdp/openthinrdp/issues/new?labels=hardware-report&title=$t&body=$b"
}
diag_text(){
  . "$OTR/lib/netif.sh"
  local IF GW h a s
  IF=$(main_nic); GW=$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)
  {
    echo "OpenThinRDP $(cat "$OTR/VERSION" 2>/dev/null)   $(hostname)   $(date '+%Y-%m-%d %H:%M')"
    echo
    echo "Network card    ${IF:-none}  $(cat "/sys/class/net/$IF/operstate" 2>/dev/null)  MAC $(cat "/sys/class/net/$IF/address" 2>/dev/null)"
    echo "IP address      $(ip -4 -o addr show dev "$IF" 2>/dev/null | awk '{print $4}' | head -1)"
    # 802.1X on the cable, as the supplicant of each adapter sees it now (dot1x.sh status needs no root)
    [ "$(cfg DOT1X)" != off ] && echo "802.1X          $("$OTR/dot1x.sh" status 2>/dev/null)"
    if [ -n "$GW" ] && command -v ping >/dev/null; then
      echo "Gateway         $GW  ($(ping -c1 -W1 "$GW" >/dev/null 2>&1 && echo "$L_DIAG_OK" || echo "$L_DIAG_FAIL"))"
    else echo "Gateway         ${GW:-none}"; fi
    echo "DNS servers     $(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf)"
    echo "Time            $(date '+%H:%M:%S'), synchronized: $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
    echo
    [ -z "$(cfg BROKER)" ] && echo "Remote desktop  no broker or PC set"
    # through an RD Gateway the brokers are not reached straight: the gateway on its HTTPS port is what counts
    s=$(cfg RDP_GATEWAY)
    if [ -n "$s" ]; then
      gp=${s##*:}; gh=${s%:*}; [ "$gh" = "$s" ] && gp=443
      a=$(getent ahostsv4 "$gh" 2>/dev/null | awk 'NR==1{print $1}')
      if [ -z "$a" ]; then echo "RD Gateway      $gh: name $L_DIAG_NOTFOUND (DNS)"
      else echo "RD Gateway      $gh ($a): port $gp $(diag_port "$a" "$gp")   use: $(cfg RDP_GATEWAY_USE)"; fi
    fi
    for h in $(cfg BROKER) $(cfg BROKER_FALLBACK); do
      a=$(getent ahostsv4 "$h" 2>/dev/null | awk 'NR==1{print $1}')
      if [ -z "$a" ]; then echo "Remote desktop  $h: name $L_DIAG_NOTFOUND (DNS)"
      else echo "Remote desktop  $h ($a): port 3389 $(diag_port "$a" 3389)"; fi
    done
    echo "Transport       $(cfg TRANSPORT), FreeRDP ${FRV:-?}$([ "$HASUDP" = 1 ] && echo ' with UDP')"
    # the state of the tunnel as the last report saw it (vpn.sh runs as root)
    [ "$(cfg VPN)" != off ] && echo "VPN             $(sed -n 's/^VPN=//p' /run/openthinrdp-status.txt 2>/dev/null | head -1)"
    s=$(cfg MGMT_SHARE); [ -z "$s" ] && s=$(cat "$OTR_LIB/share-from-domain" 2>/dev/null) && [ -n "$s" ] && s="$s (from the domain)"
    echo "Management      ${s:-none}${s:+   last report: $(tail -1 "$OTR_LOG/report.log" 2>/dev/null | cut -c1-90)}"
    echo
    echo "Last events:"
    tail -n 10 "$OTR_EVENTS" 2>/dev/null
  }
}

# --- session ------------------------------------------------------------------------------------
# xfreerdp3 exit codes (measured with FreeRDP 3.31-3.33): 12 = Disconnect or Sign out from the Start menu,
# 1 = VM shut down or restarted, disconnected by an administrator, or (Windows 11) session taken over from another
# device: vm_alive tells them apart, 147 = network lost, 5 = session taken
# over from another device (inside a session the exit code is the ERRINFO code).
# Only DELIBERATE endings lead to the shutdown page; everything else reconnects on its own.
reason(){ case "$1" in
  0) echo "closed" ;; 1) echo "VM shut down or disconnected by an administrator" ;; 2) echo "disconnected by an administrator" ;;
  3) echo "idle timeout" ;; 5) echo "session opened from another device" ;;
  11|12) echo "user disconnect or sign out" ;; 137) echo "killed (watchdog or kill -9)" ;; 147) echo "network lost" ;; *) echo "error $1" ;; esac; }
deliberate(){ case "$1" in 0|1|2|3|11|12) return 0 ;; *) return 1 ;; esac; }
# Why FreeRDP ended this session, for the event of a drop (" - text", or nothing): its last connection error
# (ERRCONNECT_/ERRINFO_), else its last error that is not the noise of the channels closing behind it. Plain "last
# ERROR" named a smart card channel failing after the UDP tunnel broke down (measured 13/10/2026).
last_error(){ local l
  l=$(grep -a '\[ERROR\]' /tmp/kiosk.log 2>/dev/null | grep -a -E 'ERRCONNECT_|ERRINFO_' | tail -1)
  [ -n "$l" ] || l=$(grep -a '\[ERROR\]' /tmp/kiosk.log 2>/dev/null | grep -a -v -E 'CHANNEL_RC_BAD|VirtualChannelWriteEx|LIBUSB_ERROR|QueryContextAttributes' | tail -1)
  l=$(echo "$l" | sed 's/.*\] - //' | tr -d '\r' | cut -c1-160); [ -n "$l" ] && echo " - $l"; }
# The VM of the session (the watchdog writes its address while connected) still accepts RDP, twice 5 s apart: it is
# not shutting down or restarting.
# Through an RD Gateway the connection is to the gateway, and the VM cannot be reached to ask: code 1 then counts
# as an ending, as with a VM that does not answer.
vm_alive(){ local a; [ -n "$(cfg RDP_GATEWAY)" ] && return 1
  a=$(cat /tmp/kiosk.vm 2>/dev/null); [ -n "$a" ] || return 1
  sleep 3; timeout 3 bash -c "exec 3<>/dev/tcp/$a/3389" 2>/dev/null || return 1
  sleep 5; timeout 3 bash -c "exec 3<>/dev/tcp/$a/3389" 2>/dev/null; }
# Is the user already connected from ANOTHER thin client? Based on the thin clients' own reports
# (report.sh writes $OTR_LIB/sessions-elsewhere: user|hostname|IP, only reports sent in the last 10 minutes),
# NOT on the Windows sessions: a disconnected session stays on the VM and would warn at every return.
# A list older than 15 minutes (management folder unreachable) is ignored. Prints "hostname (IP)" or nothing.
session_elsewhere(){ local f=$OTR_LIB/sessions-elsewhere u
  [ -f "$f" ] && [ $(( $(date +%s) - $(stat -c %Y "$f") )) -le 900 ] || return 0
  u=$(echo "$1" | tr 'A-Z' 'a-z' | sed 's/^.*\\//; s/@.*//')
  awk -F'|' -v u="$u" '$1==u{print $2 ($3 != "" ? " (" $3 ")" : ""); exit}' "$f"; }
# Why an attempt failed, to tell the user. Broker down or port closed = 141, broker name not resolved = 140,
# and in both cases the log has NO authentication line; if it has one, the broker answered and the VM is missing.
#   net = no address or gateway   dns = broker name not found   broker = no broker answers   vm = broker ok, no desktop
# IPv4 address only: "hostname -I" may list an IPv6 one first, which is not what users or support look for
ipv4(){ ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1; }
net_ok(){ ip -4 route show default 2>/dev/null | grep -q . && [ -n "$(ipv4)" ]; }
err_class(){
  case "$1" in 139|140) echo dns; return ;; esac
  if grep -qiE 'credssp|nla|license|ntlm|messageChannel|activation|redirect' /tmp/kiosk.log 2>/dev/null; then echo vm; return; fi
  case "$1" in 131|133|141|142|143|147|150) echo broker ;; *) echo other ;; esac; }
err_title(){ case "$1" in net) echo "$L_E_NET" ;; dns) echo "$L_E_DNS" ;; broker) echo "$L_E_BROKER" ;; vm) echo "$L_E_VM" ;; udp) echo "$L_E_UDP" ;; *) echo "$L_E_OTHER" ;; esac; }
# final message after the last attempt: what happened and what to do. Stays 60 s (or until OK).
show_err(){ local cl=$1 u=$2 before=$3 t sup
  sup=$(cfg SUPPORT_TEXT); [ -z "$sup" ] && sup=$L_CALL_SUPPORT
  case "$cl" in
    net)    t="$L_T_NET" ;;
    dns)    t=$(printf "$L_T_DNS" "$(cfg BROKER)")"\n$sup" ;;
    broker) t=$(printf "$L_T_BROKER" "$(cfg BROKER) $(cfg BROKER_FALLBACK)")"\n$sup" ;;
    vm)     t=$(printf "$L_T_VM" "$u")"\n$sup" ;;
    udp)    t="$L_T_UDP\n$sup" ;;
    *)      t=$(printf "$L_T_OTHER" "$LAST_EC")"\n$sup" ;;
  esac
  ui message --icon=error --heading="$(plain "${before:+$before - }$(err_title "$cl")")" --text="$(plain "$t")" \
     --small="$(hostname)  ·  IP $(ipv4)  ·  $(date '+%d/%m %H:%M')" --timeout=60 --button="$L_OK:0" --primary=0 --default=0; }
duration(){ [ "$1" -lt 120 ] && echo "$1 s" || echo "$(( $1 / 60 )) min"; }
# tenths of a second (or of a millisecond) written as 12.3
tenths(){ echo "$(( $1 / 10 )).$(( $1 % 10 ))"; }
# The quality of a session, sampled by the watchdog every ~5 s into /tmp/kiosk.quality ("<samples> <latency sum>
# <latency max> <bytes in at the start> <bytes in now> <peak kbit/s> <seconds>", latency in tenths of a ms): one
# event at its end, read by the manager (Experience)
quality_event(){ local q; read -r -a q < /tmp/kiosk.quality 2>/dev/null || return 0; rm -f /tmp/kiosk.quality
  [ "${q[0]:-0}" -ge 6 ] || return 0
  ev "session quality of $1: latency $(tenths $(( q[1] / q[0] ))) ms (max $(tenths "${q[2]}") ms), $(( (q[4] - q[3]) * 8 / 1000 / (q[6] > 0 ? q[6] : 1) )) kbit/s average (peak ${q[5]} kbit/s), $(duration "${q[6]}")"; }
# bytes received by the network adapters (not lo)
rx_bytes(){ awk 'NR > 2 { sub(/^ +/, ""); split($0, a, /[: ]+/); if (a[1] != "lo") s += a[2] } END { print s + 0 }' /proc/net/dev; }
# Broker for attempt n: the first 2 on BROKER, then in turn on BROKER_FALLBACK, so one broken broker
# does not lock anybody out while DNS round robin keeps sending half of the devices to it
pick_broker(){ local n=$1 ha=$2; set -- $(cfg BROKER_FALLBACK)
  if [ $n -le 2 ] || [ $# -eq 0 ]; then echo "$ha"; else local k=$(( (n - 3) % $# + 1 )); echo "${!k}"; fi; }

# The broker answers but the virtual machine refuses the desktop: it is restarting or installing an update. One
# wait of 20 s on a screen with Cancel, then the caller tries again; the attempts do not count meanwhile. Uses the
# locals of session (U, vmwait, vmlog). Returns 1 when the user cancels or after 20 minutes of waiting in total.
vm_wait(){ local now m rc
  now=$(date +%s)
  if [ $vmwait -eq 0 ]; then vmwait=$now; vmlog=$now; txt=$L_P_VMWAIT_T
    ev "desktop of $U not ready: the broker answers, the virtual machine does not (restarting or updating): waiting up to 20 min"; fi
  m=$(( (now - vmwait) / 60 ))
  [ $(( now - vmwait )) -ge 1200 ] && { ev "desktop of $U still not ready after $m min: giving up"; return 1; }
  [ $(( now - vmlog )) -ge 300 ] && { vmlog=$now; ev "desktop of $U: still waiting for the virtual machine ($m min)"; }
  ui message --icon=busy --heading="$(plain "$L_P_VMWAIT_T")" --text="$(plain "$(printf "$L_P_VMWAIT" "$m")")" \
     --timeout=20 --button="$L_CANCEL:1" --primary=1 --default=1
  rc=$?
  [ $rc = 1 ] && { ev "waiting for the desktop of $U cancelled by the user after $m min"; return 1; }
  return 0; }

# session USER PASSWORD [reconnect]. Returns 0 = ended deliberately, 1 = credentials refused,
# 2 = desktop not available after the attempts, 3 = session DROPPED (the caller reconnects without asking),
# 4 = session taken over from another device (warn, never reconnect: the two devices would fight)
session(){
  local U="$1" P="$2" att=0 max=8 txt="$L_P_CONNECTING" B BRHA st d ec thr xp wp udponly=0 noudp=0 vmfails=0 vmwait=0 vmlog=0 ctmo=150
  BRHA=$(cfg BROKER)
  rm -f /tmp/kiosk.cancel /tmp/kiosk.stopped /tmp/kiosk.timeout /tmp/kiosk.disconnect
  [ "$3" = reconnect ] && { max=40; txt="$L_P_RECONNECTING"; }
  LAST_ERR=""; LAST_EC=""
  thr=$(cfg_num SESSION_THRESHOLD 10)
  if [ "$(cfg TRANSPORT)" = udp ]; then
    if [ -n "$(cfg RDP_GATEWAY)" ]; then ev "TRANSPORT=udp with an RD Gateway: TCP used (FreeRDP carries no UDP through a gateway)"
    elif [ $HASUDP = 1 ]; then udponly=1; else ev "TRANSPORT=udp but this FreeRDP has no UDP transport: TCP used"; fi
  fi
  while [ $att -lt $max ]; do
    att=$((att+1))
    rm -f /tmp/kiosk.noudp
    # without a network calling the broker is pointless: say so now and retry in 5 s
    if ! net_ok; then
      LAST_ERR=net; LAST_EC=""
      ev "attempt $att for $U: no network (no address or gateway)"
      ui message --icon=warn --heading="$(plain "$L_E_NET")" --text="$(plain "$(printf "$L_P_NONET" "$att" "$max")")" --timeout=5
      continue
    fi
    # the log of the previous attempt or session stays as kiosk.log.prev: after a drop the next attempt starts at once
    [ -s /tmp/kiosk.log ] && mv -f /tmp/kiosk.log /tmp/kiosk.log.prev; : > /tmp/kiosk.log; rm -f /tmp/kiosk.vm /tmp/kiosk.quality
    st=$(date +%s)
    B=$(pick_broker $att "$BRHA")
    ( connect "$U" "$P" "$B"; echo $? > /tmp/kiosk.rc ) &
    xp=$!
    # still up after the threshold = open: the event makes report.sh send the status at once, so the other
    # thin clients soon know the user is connected here ("already active" warning)
    ( sleep "$thr"; kill -0 $xp 2>/dev/null && ev "session of $U opened (broker $B)" ) &
    wp=$!
    {
      echo "8"; echo "# $txt  ($(printf "$L_P_ATTEMPT" "$att")$([ "$B" != "$BRHA" ] && echo ", $B"))"
      # Progress from what really happens (FreeRDP logs almost nothing at its usual level): connected to the broker,
      # redirected to the virtual machine (a connection to another address), the desktop window on screen. With the
      # window the screen closes (100); a closed screen must not end this loop (watchdog): writes ignore SIGPIPE.
      trap '' PIPE
      local s1=0 s2=0 s3=0 n=0 s1n=0 s1w="" seen=0 lost=0 tcponly=0 fp ips first="" q lastq=0 stuck=0 stopped=0 ui uo lui="" luo=0 lut=0
      # the times of the sign-in (in tenths of a second): the broker, the VM made ready, Windows until the desktop
      local t0 t1="" t2="" t3 qn=0 qs=0 qm=0 qrx0=0 qrx qpk=0 qt0=0 qlr=0 qlt=0 r
      t0=$(date +%s%1N)
      # the UTC offset the session started with: Windows takes the time zone of the device only when a session
      # opens (time zone redirection), so a session open across a change of the clock (daylight saving time)
      # stayed one hour off until it was opened again (26/10/2026, two sessions open since Friday)
      local tzo; tzo=$(date +%z)
      while kill -0 $xp 2>/dev/null; do
        fp=$(pgrep -P $xp -x xfreerdp3 | head -1)
        # Cancel pressed before FreeRDP was there: it goes as soon as it is
        [ -f /tmp/kiosk.cancel ] && [ -n "$fp" ] && kill -9 "$fp" 2>/dev/null
        if [ -n "$fp" ] && [ $s3 -eq 0 ]; then
          ips=$(ss -tnpH state established 2>/dev/null | grep "pid=$fp," | awk '{print $4}' | sed 's/:[0-9]*$//' | sort -u)
          [ -z "$first" ] && first=$(echo "$ips" | head -1)
          if [ $s1 -eq 0 ] && [ -n "$ips" ]; then echo "30"; echo "# $L_P_AUTH"; s1=1; s1n=$n; t1=$(date +%s%1N); fi
          # still on the broker after 5 s: it is preparing the virtual machine, usually starting it
          if [ $s1 -eq 1 ] && [ $s2 -eq 0 ] && [ -z "$s1w" ] && [ $((n - s1n)) -ge 12 ]; then echo "45"; echo "# $L_P_VMSTART"; s1w=1; fi
          if [ $s2 -eq 0 ] && [ -n "$first" ] && echo "$ips" | grep -qvx "$first"; then echo "65"; echo "# $L_P_STARTING"; s2=1; t2=$(date +%s%1N); fi
          if xdotool search --onlyvisible --pid "$fp" >/dev/null 2>&1; then pointer_show; echo "# $L_P_READY"; echo "100"; s3=1
            t3=$(date +%s%1N); t1=${t1:-$t3}; t2=${t2:-$t1}
            ev "sign-in of $U: $(tenths $((t3 - t0))) s (broker $(tenths $((t1 - t0))) s, VM $(tenths $((t2 - t1))) s, Windows $(tenths $((t3 - t2))) s)$([ "$3" = reconnect ] && echo ', reconnection')"
            ( sleep 15; sudo -n "$OTR/usb-hold.sh" release >/dev/null 2>&1 ) & echo $! > /tmp/kiosk.usbrel; fi
        fi 2>/dev/null
        sleep 0.4; n=$((n + 1))
        # Watchdog, every ~5 s: FreeRDP alive but without any TCP connection for 60 s = stuck. Seen with USB
        # redirection: a USB hotplug event during the disconnect deadlocks urbdrc against drdynvc and the
        # process never exits, so the screen stays frozen and nothing reconnects. Killed, it exits with 137
        # and the session is reopened like after any drop.
        [ $((n % 12)) -eq 0 ] || continue
        fp=$(pgrep -P $xp -x xfreerdp3 | head -1); [ -n "$fp" ] || continue
        # Watchdog 4: the clock changed (daylight saving time): the session is opened again at once, like after a
        # drop (code 137, a few seconds, the programs stay open on the server), so Windows shows the new time
        if [ $s3 -eq 1 ] && [ "$(date +%z)" != "$tzo" ]; then ev "session of $U: the time changed ($tzo to $(date +%z), daylight saving time), opened again so Windows shows the new time"; tzo=$(date +%z); kill -9 "$fp"; continue; fi
        # Stopped by the kernel (state T: it tried the console, or anything else that stops it) for 10 s: it never
        # goes on by itself. What it was doing kept, killed, the attempt ends with an error (not a drop to retry).
        if [ "$(awk '/^State/{print $2}' /proc/"$fp"/status 2>/dev/null)" = T ]; then stopped=$((stopped + 5))
          if [ $stopped -ge 10 ]; then hang_report "$fp"; ev "watchdog: FreeRDP stopped (state T) for 10 s, killed"; touch /tmp/kiosk.stopped; kill -9 "$fp"; continue; fi
        else stopped=0; fi
        # No desktop yet after CONNECT_TIMEOUT seconds (a VM that starts takes one or two minutes): this attempt
        # ends, said on the screen. The Cancel button ends it earlier.
        if [ $s3 -eq 0 ] && [ $(( $(date +%s) - st )) -ge "$ctmo" ]; then ev "connection of $U: no desktop after $ctmo s, stopped"; touch /tmp/kiosk.timeout; kill -9 "$fp"; continue; fi
        if ss -tnpH state established 2>/dev/null | grep -q "pid=$fp,"; then seen=1; lost=0
          # Watchdog 2: connected, but FreeRDP no longer reads. Data waits in its sockets and the queue never shrinks
          # for 60 s (a working FreeRDP empties it all the time, even under load). Seen during a call with
          # microphone and camera: the server stopped sending at 09:46, the connection stayed up, the screen stayed
          # frozen for hours until the device was switched off. What it was doing goes to session-hang.log first.
          q=$(recvq "$fp")
          if [ "$q" -gt 0 ] && [ "$q" -ge "$lastq" ]; then stuck=$((stuck + 5)); else stuck=0; fi; lastq=$q
          if [ $stuck -ge 60 ]; then
            hang_report "$fp"; ev "watchdog: FreeRDP connected but no longer reading for 60 s ($q bytes waiting), killed (session-hang.log)"
            kill -9 "$fp"; stuck=0
          fi
          # Watchdog 3: the UDP transport stalled. FreeRDP keeps sending over UDP (input, acknowledgements, resends)
          # and for 60 s nothing comes back: the server no longer sends the screen. Seen twice during calls with
          # camera and microphone (21 and 23/10/2026, VM event 145 "no updates for 11038 s"): the pointer moved, the
          # picture and the sound were stuck, nothing waited unread (watchdog 2 saw nothing). An idle session sends
          # nothing and is never taken for one. Killed, it reconnects over TCP until the device restarts.
          if ss -uanpH 2>/dev/null | grep -q "pid=$fp,"; then
            read -r ui uo < <(udp_counts)
            if [ "$ui" != "$lui" ]; then lui=$ui; luo=$uo; lut=$(date +%s)
            elif [ $(( $(date +%s) - lut )) -ge 60 ] && [ $((uo - luo)) -ge 20 ]; then
              hang_report "$fp"; ev "watchdog: FreeRDP received nothing over UDP for $(( $(date +%s) - lut )) s while it sent $((uo - luo)) datagrams, killed: TCP until the device restarts (session-hang.log)"
              [ "$(cfg TRANSPORT)" = auto ] && touch /tmp/kiosk.udpstall
              kill -9 "$fp"; lui=""
            fi
          else lui=""; fi
          # the quality of the session for the manager (Experience): the latency of the connection to the VM, what comes in
          if [ $s3 -eq 1 ]; then
            r=$(ss -tinpH state established 2>/dev/null | grep -A1 "pid=$fp," | grep -o 'rtt:[0-9.]*' | tail -1 | cut -d: -f2)
            qrx=$(rx_bytes); r=$(awk -v r="$r" 'BEGIN { printf "%d", r * 10 + 0.5 }')
            if [ $qn -eq 0 ] && [ $qt0 -eq 0 ]; then qrx0=$qrx; qt0=$(date +%s); qlr=$qrx; qlt=$qt0; fi
            if [ "$r" -gt 0 ]; then qn=$((qn + 1)); qs=$((qs + r)); [ "$r" -gt $qm ] && qm=$r; fi
            if [ $(( $(date +%s) - qlt )) -gt 0 ]; then r=$(( (qrx - qlr) * 8 / 1000 / ($(date +%s) - qlt) )); [ $r -gt $qpk ] && qpk=$r; qlr=$qrx; qlt=$(date +%s); fi
            [ $qn -gt 0 ] && echo "$qn $qs $qm $qrx0 $qrx $qpk $(( $(date +%s) - qt0 ))" > /tmp/kiosk.quality
          fi
          # the server it is connected to now, after the broker's redirect the VM (vm_alive)
          ss -tnpH state established 2>/dev/null | grep "pid=$fp," | awk '{print $4}' | sed 's/:[0-9]*$//' | tail -1 > /tmp/kiosk.vm
          # TRANSPORT=udp: connected for 30 s without a UDP socket = UDP blocked, or FreeRDP fell back to TCP
          # after a UDP failure. The connection ends and counts as a failed attempt: the next one tries UDP.
          if [ $udponly = 1 ]; then
            if ss -uanpH 2>/dev/null | grep -q "pid=$fp,"; then tcponly=0; else tcponly=$((tcponly + 5)); fi
            [ $tcponly -ge 30 ] && { ev "UDP only: the session of $U runs without UDP, closed"; touch /tmp/kiosk.noudp; kill -9 "$fp"; }
          fi
        elif [ $seen = 1 ]; then
          lost=$((lost + 5))
          [ $lost -ge 60 ] && { ev "watchdog: FreeRDP alive without any connection for 60 s, killed"; kill -9 "$fp"; }
        fi
      done
      echo "100"; echo "# $L_P_READY"
    } | { if [ $GREETER = 1 ]; then ui message --progress --icon=busy --heading="$(plain "$L_P_TITLE")" --text="$(plain "$txt")" --button="$L_CANCEL:30"
          else yad --progress --auto-close --undecorated --skip-taskbar --center --width=470 \
            --title="$TITLE" --text="$L_P_TITLE" --button="$L_CANCEL:30" 2>/dev/null; fi
        # Cancel while it connects: this attempt ends now, back to the sign-in screen (no retry, no error)
        if [ $? -eq 30 ]; then touch /tmp/kiosk.cancel; kill -9 $(pgrep -P $xp -x xfreerdp3) 2>/dev/null; fi; }
    wait $xp 2>/dev/null
    kill $wp 2>/dev/null
    # ended before the USB devices came back: back now (a pending release must not hit the next connection)
    kill "$(cat /tmp/kiosk.usbrel 2>/dev/null)" 2>/dev/null; rm -f /tmp/kiosk.usbrel
    [ -s /run/openthinrdp-usb-held ] && sudo -n "$OTR/usb-hold.sh" release >/dev/null 2>&1
    pointer_idle_hide
    d=$(( $(date +%s) - st )); ec=$(cat /tmp/kiosk.rc 2>/dev/null)
    SESS_SECS=$d
    quality_event "$U"
    # Ended by the Cancel button (5: back to the sign-in, no message), or killed stuck or without a desktop in
    # time (6: said on the screen, never retried by itself)
    if [ -f /tmp/kiosk.cancel ]; then rm -f /tmp/kiosk.cancel /tmp/kiosk.stopped /tmp/kiosk.timeout; ev "connection of $U cancelled with the button after ${d}s"; return 5; fi
    # disconnected by an administrator from the manager (the flag, then FreeRDP ended): the session stays open on its
    # desktop, this device goes back to the sign-in and does not reconnect
    if [ -f /tmp/kiosk.disconnect ]; then rm -f /tmp/kiosk.disconnect; ev "session of $U disconnected from the manager after $(duration $d)"; return 5; fi
    if [ -f /tmp/kiosk.stopped ] || [ -f /tmp/kiosk.timeout ]; then
      if [ -f /tmp/kiosk.stopped ]; then STOP_MSG=$L_E_STOPPED; else STOP_MSG=$(printf "$L_E_TIMEOUT" "$ctmo"); fi
      rm -f /tmp/kiosk.stopped /tmp/kiosk.timeout; return 6
    fi
    # credentials: from the EXIT CODE and first, at any duration. Never retry a wrong password (the attempts
    # would lock the account). 134 = wrong password (measured), 132 authentication, 154 wrong password,
    # 135 locked, 148/149/152 expired or must change, 151 disabled, 155-159 access denied or restricted
    CRED_MSG=""
    case "$ec" in
      132|134|154) CRED_MSG=$L_C_INVALID ;;
      135)         CRED_MSG=$L_C_LOCKED ;;
      148|149|152) CRED_MSG=$L_C_EXPIRED ;;
      151|157)     CRED_MSG=$L_C_DISABLED ;;
      155|156|158|159) CRED_MSG=$L_C_DENIED ;;
    esac
    if [ -n "$CRED_MSG" ]; then ev "sign-in refused for $U (code $ec)"; return 1; fi
    # UDP only and closed for running without UDP: a failed attempt, also after a long session. Three in a
    # row = UDP does not get through: say so instead of cutting the user off every 30 s
    if [ -f /tmp/kiosk.noudp ]; then
      rm -f /tmp/kiosk.noudp; noudp=$((noudp + 1)); LAST_EC=$ec; LAST_ERR=udp
      [ $noudp -ge 3 ] && break
      txt="$L_E_UDP, $L_P_RETRY"; sleep 5; continue
    fi
    # 5 = ERRINFO_DISCONNECTED_BY_OTHER_CONNECTION: same user signed in from another device. Never retry,
    # also during a reconnection: taking the session back would drop the other device, which would do the same
    if [ "$ec" = 5 ]; then ev "session of $U taken over by another device after $(duration $d) (code 5): no reconnection"; return 4; fi
    # a session that lasted at least SESSION_THRESHOLD was open: only the exit code counts.
    # Exception: code 1 below 20 s stays an attempt (seen once while re-entering a session: with the shutdown
    # page the countdown would have switched the device off)
    if [ "$d" -ge "$thr" ] && ! { [ "$ec" = 1 ] && [ "$d" -lt 20 ]; }; then
      # A VM that is still booting or finishing an update accepts the session and drops it after ~22 s with the
      # desktop never activated (ERRCONNECT_ACTIVATION_TIMEOUT; VM-MARIA 13/10/2026 after a feature update, 7 times
      # in a row). The first one is retried at once, from the second on it is the wait for Windows; during the wait
      # any early drop is part of it.
      if [ "$d" -lt 90 ] && ! deliberate "$ec" && { [ $vmwait -gt 0 ] || grep -q 'ERRCONNECT_ACTIVATION_TIMEOUT' /tmp/kiosk.log; }; then
        vmfails=$((vmfails+1))
        if [ $vmwait -gt 0 ] || [ $vmfails -ge 2 ]; then vm_wait && { att=$((att-1)); continue; }; break; fi
        ev "session of $U dropped after $(duration $d) before the desktop was ready (code $ec): trying again$(last_error)"
        sleep 2; continue
      fi
      # Code 1 ("disconnection initiated by an administrative tool on the server") means: an administrator
      # disconnected the session, or the VM is shutting down or restarting. Both must end on the shutdown page,
      # never reconnect (the administrator would see the user come straight back, the VM would be started again).
      # The server also sends it when it closes a session the kiosk has just reopened after a drop: only then,
      # within 2 minutes of the automatic reconnection and once every 5 minutes, it counts as one more drop.
      # (A user disconnect or sign out from Windows ends with 12.)
      if [ "$ec" = 1 ] && [ "$3" = reconnect ] && [ "$d" -lt 120 ] && [ $(( $(date +%s) - ${LAST_EC1:-0} )) -gt 300 ]; then
        LAST_EC1=$(date +%s); ev "session of $U closed by the server $(duration $d) after the automatic reconnection (code 1): reconnecting once more"; return 3
      fi
      # Windows 11 also sends 1, never 5, when another device takes the session over, directly on the VM or through
      # the broker (measured 13/10/2026). A VM that still answers did not shut down: the session was taken over or
      # disconnected on the server. Same page as code 5: no reconnection, Resume here on request.
      if [ "$ec" = 1 ] && vm_alive; then
        ev "session of $U disconnected after $(duration $d) while its VM still runs (code 1): taken over by another device or disconnected on the server, no reconnection"; return 4
      fi
      if deliberate "$ec"; then ev "session of $U ended after $(duration $d) ($(reason "$ec"), code $ec)"; return 0; fi
      ev "session of $U DROPPED after $(duration $d) ($(reason "$ec"), code $ec): reconnecting$(last_error)"; return 3
    fi
    LAST_EC=$ec; LAST_ERR=$(err_class "$ec")
    # the broker answered and the VM refused twice in a row: it is restarting or updating, wait for it instead of
    # spending the attempts (VM-MARIA 13/10/2026: 16 attempts and "desktop not available" during a Windows update)
    if [ "$LAST_ERR" = vm ]; then vmfails=$((vmfails+1)); else vmfails=0; fi
    if [ $vmwait -gt 0 ] || [ $vmfails -ge 2 ]; then
      [ $vmwait -eq 0 ] && ev "attempt $att for $U on $B failed after ${d}s (code $ec, $LAST_ERR): $(grep -m1 -E '\[ERROR\]' /tmp/kiosk.log | sed 's/.*\] - //' | cut -c1-150)"
      vm_wait && { att=$((att-1)); continue; }
      break
    fi
    ev "attempt $att for $U on $B failed after ${d}s (code $ec, $LAST_ERR): $(grep -m1 -E '\[ERROR\]' /tmp/kiosk.log | sed 's/.*\] - //' | cut -c1-150)"
    txt="$(err_title $LAST_ERR), $L_P_RETRY"
    sleep 5
  done
  ev "desktop not available for $U after $att attempts: $LAST_ERR"
  return 2
}

# --- kiosk page (WEB_BUTTON=kiosk) --------------------------------------------------------------
# A page opened without a network would stay on the error: wait for the network up to 60 s.
kiosk_page(){
  local url i; url=$(cfg KIOSK_URL); [ -z "$url" ] && return 1
  for i in $(seq 1 60); do net_ok && break; sleep 1; done
  ev "kiosk page: opening $url"
  "$OTR/browser.sh" kiosk "$url"
  ev "kiosk page: closed"
}
# Countdown of the login form in kiosk mode: if within 5 s nobody touches the screen, moves the mouse or
# presses a key, close the form and mark "expired" (-> page). Any input stops it and the form stays.
# Without mouse and keyboard the page starts by itself. Without xprintidle: plain countdown.
KEXP=/tmp/otr-kiosk-expired
kiosk_countdown(){
  local t0 el idle i; t0=$(date +%s%3N)
  for i in $(seq 1 50); do
    sleep 0.1
    if command -v xprintidle >/dev/null; then
      idle=$(xprintidle 2>/dev/null); el=$(( $(date +%s%3N) - t0 ))
      # input arrived after the form appeared (300 ms margin for the window to open): stopped, from now on
      # the 5 minutes without input rule applies
      [ -n "$idle" ] && [ "$idle" -lt $(( el - 300 )) ] && [ $el -gt 600 ] && { kiosk_idle; return; }
    fi
  done
  touch $KEXP; pkill -f -- '--class=OtrLogin' 2>/dev/null
}
# kiosk stopped by hand and then left alone: after 5 minutes without input the page comes back
kiosk_idle(){
  local idle
  while sleep 5; do idle=$(xprintidle 2>/dev/null); [ -n "$idle" ] && [ "$idle" -gt 300000 ] && break; done
  touch $KEXP; pkill -f -- '--class=OtrLogin' 2>/dev/null
}
# power_off REASON [reboot]: switch off (or restart), after a software update that is installing
power_off(){
  local act=poweroff; [ "$2" = reboot ] && act=reboot
  ev "$([ $act = reboot ] && echo restart || echo 'power off') ($1)"
  if updating; then
    ev "$act waits for the software update to finish"
    echo $act > /tmp/openthinrdp-poweroff-pending   # install.sh does not restart the X session, auto-update.sh does this
    # full screen with the progress; ends when the update is over
    ui message --update --icon=update --heading="$(plain "$L_UPDATE_RUNNING")" --text="$(plain "$L_WAIT_UPDATE") (%p%)"
    wait_update
  fi
  sleep 1; systemctl $act; exit 0
}
# the sign-in screen (login.py, GTK); without the Python GTK bindings (a device updated without the Debian mirror)
# the yad form of the earlier versions
GREETER=0
python3 -c 'import gi; gi.require_version("Gtk", "3.0"); from gi.repository import Gtk' 2>/dev/null && GREETER=1
# ui MODE ARGS...: the screens of ui.py (sign-in, messages, progress) with the colors and pictures of the site
ui(){ local m=$1; shift; python3 "$OTR/ui.py" "$m" --title="$TITLE" --lang="$(cfg LANGUAGE)" --top="$(cfg BG_TOP)" --bottom="$(cfg BG_BOTTOM)" \
        --splash="$SPLASH" --logo="$LOGO" "$@" 2>/dev/null; }
# plain text for ui.py: no Pango tags
plain(){ printf '%s' "$1" | sed 's/<[^>]*>//g'; }
# --- updates of a device without a management folder: asked on its screen ----------------------------------------
# With central settings (a management folder, the manager) the site decides and nothing is asked here. Without them
# (the live system from the USB stick, an image of its own with site.conf only) nobody else decides: auto-update.sh
# offers every new version (/run/openthinrdp-update-offer: "<new> <current> [<major>]") with its changes, and this
# asks at the sign-in screen. A normal update: Enter or 30 s without an answer installs it. A major update (a change
# to how a session connects or runs): only with a yes. Not now: until the next start. The install restarts the kiosk.
managed(){ [ -s "$OTR_LIB/central-common.conf" ]; }
update_question(){
  local i v cur maj rc
  [ -f /run/openthinrdp-update-offer ] && [ ! -f /tmp/openthinrdp-update-declined ] || return 0
  read -r v cur maj < /run/openthinrdp-update-offer; [ -n "$v" ] || return 0
  [ "$(cat /tmp/openthinrdp-update-accepted 2>/dev/null)" = "$v" ] && return 0
  if [ -n "$maj" ]; then
    ui text --heading="$(plain "$(printf "$L_UPD_MAJOR_T" "$v")")" --text="$(plain "$(printf "$L_UPD_MAJOR" "$cur" "$v")")" \
       --t-close="$L_UPD_NOTNOW" --button="$(printf "$L_UPD_GET" "$v"):1" < /run/openthinrdp-update-notes
  else
    ui text --heading="$(plain "$L_UPD_OFFER_T")" --text="$(plain "$(printf "$L_UPD_OFFER" "$cur" "$v")")" --timeout=30 \
       --t-close="$L_UPD_NOTNOW" --button="$(printf "$L_UPD_GET" "$v"):1" --primary=1 < /run/openthinrdp-update-notes
  fi
  rc=$?
  # 1 = install; 70 = 30 s without an answer (a normal update only: the major question has no timeout)
  if [ $rc != 1 ] && [ $rc != 70 ]; then
    : > /tmp/openthinrdp-update-declined; ev "software update $v not now, on the device: staying on $cur until the next start"; return 0
  fi
  # the event starts report.sh, which installs it; the install restarts this kiosk with the new version
  echo "$v" > /tmp/openthinrdp-update-accepted; ev "software update $v chosen on the device$([ -n "$maj" ] && echo ' (major update)')"
  { echo "10"; echo "# $(printf "$L_UPD_GET" "$v")"
    for i in $(seq 1 120); do updating && break; sleep 0.5; done
    echo "100"; } | ui message --progress --icon=update --heading="$(plain "$L_UPDATE_RUNNING")" --text="$(plain "$(printf "$L_UPD_GET" "$v")")"
  ui message --update --icon=update --heading="$(plain "$L_UPDATE_RUNNING")" --text="$(plain "$L_UPD_INSTALL") (%p%)"
  wait_update
}
# At the start of a device without a management folder: the answer of the update source first (45 s at most, with a
# network within 20 s), so the question comes before anyone signs in. The image does not need rebuilding per release.
start_update_check(){
  local i
  managed || [ "$(cfg UPDATE_FROM)" = off ] && return 0
  . "$OTR/lib/netif.sh"
  for i in $(seq 1 40); do ip -4 -o addr show dev "$(main_nic)" 2>/dev/null | grep -q inet && break; sleep 0.5; done
  ip -4 -o addr show dev "$(main_nic)" 2>/dev/null | grep -q inet || return 0
  if [ ! -f /run/openthinrdp-update-offer ] && [ ! -f /run/openthinrdp-update-checked ]; then
    { echo "15"; echo "# $L_UPD_CHECK"
      for i in $(seq 1 90); do [ -f /run/openthinrdp-update-offer ] || [ -f /run/openthinrdp-update-checked ] && break; sleep 0.5; done
      echo "100"; } | ui message --progress --icon=busy --heading="$(plain "$L_UPD_CHECK_T")" --text="$(plain "$L_UPD_CHECK")"
  fi
  update_question
}
start_update_check
# the live system (from the USB stick) tests the hardware at its first start: what anyone trying it wants to know
otr_installed || [ -f /tmp/openthinrdp-selftest-shown ] || { : > /tmp/openthinrdp-selftest-shown; selftest_dialog; }

# --- main loop ----------------------------------------------------------------------------------
# first start: no broker yet -> the settings dialog opens by itself (it is the setup of a new device).
# A new device takes its name from the MAC address in the boot service, which runs alongside: wait for it (20 s
# at most), otherwise the dialog shows "thinclient" and saving it would undo the new name.
if [ -z "$(cfg BROKER)" ]; then
  for i in $(seq 1 40); do
    [ "$(hostname)" != thinclient ] && break
    case "$(systemctl show -p ActiveState --value openthinrdp-boot.service 2>/dev/null)" in active|failed) break ;; esac
    sleep 0.5
  done
  ev "no broker configured: settings dialog opened"; settings_dialog
fi
KSTOPPED=0   # 1 = somebody used the form: no countdown until we go back to the page
while true; do
  # a new version offered to a device without a management folder: asked before the sign-in screen (update_question)
  update_question
  look
  HOSTN=$(hostname 2>/dev/null)
  WEB=$(cfg WEB_BUTTON); WEBBTN=()
  case "$WEB" in app|browser) WEBBTN=(--button="$(cfg WEB_LABEL):7") ;; kiosk) WEBBTN=(--button="$L_KIOSK:7") ;; esac
  KTXT=""; KPID=""; rm -f $KEXP
  [ -z "$(cfg BROKER)" ] && KTXT="\n<small>$L_NO_BROKER</small>"
  if [ "$WEB" = kiosk ]; then
    if [ -z "$(cfg KIOSK_URL)" ]; then KTXT="\n<small>$L_K_NOPAGE</small>"
    elif [ $KSTOPPED -eq 0 ]; then KTXT="\n<small>$L_K_COUNTDOWN</small>"; kiosk_countdown & KPID=$!
    elif command -v xprintidle >/dev/null; then KTXT="\n<small>$L_K_IDLE</small>"; kiosk_idle & KPID=$!
    fi
  fi
  # IP only if already there: the form does not wait for it (it is always shown in the settings dialog)
  IPNOW=$(ipv4)
  if [ $GREETER = 1 ]; then
    WEBL=""; case "$WEB" in app|browser) WEBL=$(cfg WEB_LABEL) ;; kiosk) WEBL=$L_KIOSK ;; esac
    NOTE=$(printf '%b' "$KTXT" | sed 's/<[^>]*>//g; /^$/d')
    OUT=$(ui login --class=OtrLogin --heading="$L_LOGIN_HEADING" \
          --info="$HOSTN${IPNOW:+  ·  $IPNOW}" --note="$NOTE" --user="$DEF" \
          --web="$WEBL" --t-user="$L_USER" --t-password="$L_PASSWORD" \
          --t-signin="$L_SIGNIN" --t-shutdown="$L_SHUTDOWN" --t-restart="$L_RESTART" --t-settings="$L_SETTINGS" \
          --t-diag="$L_DIAG" --t-power="$L_POWER" \
          --t-net="$L_NET_CABLE|$L_NET_WIFI|$L_NET_NONE|$L_NET_NOIP" 2>/dev/null)
    rc=$?
  else
    # Enter in the password field presses the LAST button: Sign in goes last with the highest code
    OUT=$(yad --form $IMG --class=OtrLogin --title="$TITLE" \
          --text="<b>$L_LOGIN_HEADING</b>   [ $HOSTN${IPNOW:+  -  IP $IPNOW} ]$KTXT" \
          --separator="|" --field="$L_USER" --field="$L_PASSWORD:H" --focus-field=2 --width=430 --center \
          --button="$L_SHUTDOWN:5" --button="⚙:3" --button="ℹ:4" "${WEBBTN[@]}" --button="$L_SIGNIN:10" "$DEF" "" 2>/dev/null)
    rc=$?
  fi
  # kiosk: nobody touched anything -> page; otherwise the form stays without countdown
  if [ -n "$KPID" ]; then
    kill $KPID 2>/dev/null; wait $KPID 2>/dev/null
    if [ -f $KEXP ]; then rm -f $KEXP; KSTOPPED=0; kiosk_page; continue; fi
    # stopped only when a button closed the form: closed by monitor_watch (late monitor) = draw it again
    case $rc in 0|3|4|5|6|7|8|10) [ $KSTOPPED -eq 0 ] && ev "kiosk page: start stopped by the user"; KSTOPPED=1 ;; *) continue ;; esac
  fi
  # the power menu of the sign-in screen is already a deliberate choice: no second question
  [ $rc -eq 6 ] && power_off "Restart button" reboot
  [ $rc -eq 5 ] && [ $GREETER = 1 ] && power_off "Shut down button"
  if [ $rc -eq 5 ]; then
    # dialog WITHOUT fields: Enter presses the FIRST button -> No goes first
    yad $IMG --title="$TITLE" --width=360 --center --text="<b>$L_ASK_SHUTDOWN</b>" \
        --button="$L_NO:1" --button="$L_YES_SHUTDOWN:5" 2>/dev/null
    [ $? -eq 5 ] && power_off "Shut down button"
    continue
  fi
  [ $rc -eq 3 ] && { settings_dialog; continue; }
  # the network on the sign-in screen pressed: the Wi-Fi page, behind the PIN of the settings
  [ $rc -eq 8 ] && { pin_ok && wifi_page; continue; }
  [ $rc -eq 4 ] && { diag_dialog; continue; }
  if [ $rc -eq 7 ]; then
    [ "$WEB" = kiosk ] && { KSTOPPED=0; kiosk_page; continue; }
    "$OTR/browser.sh"; continue
  fi
  { [ $rc -eq 10 ] || [ $rc -eq 0 ]; } || { sleep 1; continue; }
  U=$(echo "$OUT" | cut -d'|' -f1); P=$(echo "$OUT" | cut -d'|' -f2-); P=${P%|}
  # an empty field = the default user AS IT IS NOW (read again: the form may have been drawn before the central
  # settings brought it); still nobody = the name is asked, never a connection without a user (FreeRDP would ask for
  # it on the console nobody sees)
  [ -z "$U" ] && U=$(cfg DEFAULT_USER); [ -z "$P" ] && continue
  if [ -z "$U" ]; then ui message --icon=warn --text="$(plain "$L_E_NOUSER")" --timeout=8 --button="$L_OK:0" --primary=0 --default=0; continue; fi
  OTHER=$(session_elsewhere "$U")
  if [ -n "$OTHER" ]; then
    # dialog WITHOUT fields: Enter presses the FIRST button -> Cancel (nobody drops a colleague by mistake)
    ui message --icon=warn --text="$(plain "$(printf "$L_ELSEWHERE" "$U" "$OTHER")")" \
       --button="$L_CANCEL:1" --button="$L_CONNECT_ANYWAY:10" --primary=1 --default=1
    [ $? -eq 10 ] || { ev "sign-in of $U cancelled: session already active on $OTHER"; continue; }
    ev "session of $U already active on $OTHER: connecting here confirmed"
  fi
  MODE=""; DROPS=0
  while true; do
    session "$U" "$P" $MODE; res=$?
    # dropped: back into the same session without asking (never the shutdown page); after 20 drops in a row
    # back to the login. A session that stayed up at least 5 minutes resets the count.
    if [ $res -eq 3 ]; then
      [ "${SESS_SECS:-0}" -ge 300 ] && DROPS=0
      DROPS=$((DROPS+1)); MODE=reconnect
      [ $DROPS -le 20 ] && { sleep 2; continue; }
      ev "too many drops in a row for $U: back to the login"; break
    fi
    if [ $res -eq 2 ] && [ "$MODE" = reconnect ]; then show_err "$LAST_ERR" "$U" "$L_E_NOTRESTORED"; break; fi
    MODE=""; DROPS=0
    # cancelled with the button: straight back to the sign-in; stuck or too slow: said, then back to the sign-in
    [ $res -eq 5 ] && break
    if [ $res -eq 6 ]; then
      ui message --icon=error --text="$(plain "$STOP_MSG")" --small="$(hostname)  ·  IP $(ipv4)  ·  $(date '+%d/%m %H:%M')" \
         --timeout=60 --button="$L_OK:0" --primary=0 --default=0
      break
    fi
    if [ $res -eq 4 ]; then
      # no reconnection; the user moved to the other device -> this one switches off after 30 s.
      # Dialog WITHOUT fields: Enter presses the FIRST button -> Back to login; Resume here only by click
      ui message --icon=warn --text="$(plain "$(printf "$L_TAKEN" "$U")")" --timeout=30 \
         --button="$L_BACK_LOGIN:1" --button="$L_RESUME_HERE:10" --button="$L_SHUTDOWN:5" --primary=1 --default=1
      rc=$?
      [ $rc -eq 10 ] && { ev "session of $U resumed on this device (user choice)"; continue; }
      { [ $rc -eq 5 ] || [ $rc -eq 70 ]; } && power_off "session taken over by another device"
      break
    fi
    if [ $res -eq 0 ]; then
      OFF=$(cfg_num SHUTDOWN_SECS 10); TOPT=(); TXT=$L_END_ASK
      [ "$OFF" -gt 0 ] && { TOPT=(--timeout="$OFF"); TXT=$(printf "$L_END_COUNTDOWN" "$OFF"); }
      # Enter = Connect. 10/0 = Connect, 5 = Shut down, 70 = countdown expired, anything else = login
      ui message --icon=power --heading="$(plain "$L_END_TITLE")" --text="$(plain "$TXT")" "${TOPT[@]}" \
         --button="$L_SHUTDOWN:5" --button="$L_CONNECT:10" --primary=10 --default=10
      rc=$?
      { [ $rc -eq 10 ] || [ $rc -eq 0 ]; } && continue
      { [ $rc -eq 5 ] || [ $rc -eq 70 ]; } && power_off "after the session ended"
      break
    elif [ $res -eq 1 ]; then
      ui message --icon=error --text="$(plain "${CRED_MSG:-$L_C_INVALID}")" --timeout=8 --button="$L_OK:0" --primary=0 --default=0; break
    else
      show_err "$LAST_ERR" "$U"; break
    fi
  done
done
