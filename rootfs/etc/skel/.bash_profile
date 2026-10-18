# automatic login on tty1 starts X; the splash stays on screen until the kiosk draws its background
if [ -z "$DISPLAY" ] && [ "$(tty)" = /dev/tty1 ]; then
  # A new device renames itself at its first start (boot.sh, from the MAC address). X must start after that: started
  # under the old name it keeps a cookie for that name, and after the rename no program can open the screen (the
  # settings of a new device stayed black). Without a TPM nothing slows the boot down, so the login can come first.
  # At most 10 s: X always starts.
  for i in $(seq 1 50); do [ -e /run/openthinrdp-name-ready ] && break; sleep 0.2; done
  exec startx -- -background none >/tmp/startx.log 2>&1
fi
