#!/bin/bash
# The password remembered for the default user (REMEMBER_PASSWORD=on, in a workgroup above all: power on, and the
# desktop opens). A secret of the device like the others (lib/secrets.sh): sealed in the TPM when there is one, else a
# root-only file. Runs as root (sudo from the kiosk):
#   remember.sh store USER   the password on stdin; kept only with REMEMBER_PASSWORD=on and USER the default user
#   remember.sh get          "user<TAB>password" for the default user of now; nothing (exit 1) otherwise
#   remember.sh mac HOST MAC the MAC address of a computer, learnt for Wake-on-LAN (in /var/lib/openthinrdp/wake)
#   remember.sh forget       the password goes (setting off, or a password Windows refused)
. /opt/openthinrdp/lib/common.sh
. /opt/openthinrdp/lib/secrets.sh
on(){ [ "$(cfg REMEMBER_PASSWORD)" = on ]; }
case "$1" in
  store)
    on || exit 1
    u=$2; [ -n "$u" ] && [ "$u" = "$(cfg DEFAULT_USER)" ] || exit 1
    p=$(head -c 1024); [ -n "$p" ] || exit 1
    t=$(mktemp); chmod 600 "$t"; printf '%s\t%s' "$u" "$p" > "$t"
    # the same one again: nothing written (a TPM write at every sign-in for nothing)
    f=$(secret_path rdp-login)
    if [ -s "$f" ] && cmp -s "$t" "$f"; then rm -f "$t"; exit 0; fi
    install -d -m 700 "$OTR_ETC"; secret_store rdp-login "$t"; ev "password of $u remembered" ;;
  get)
    on || exit 1
    f=$(secret_path rdp-login); [ -s "$f" ] || exit 1
    IFS=$'\t' read -r u p < "$f"
    [ -n "$p" ] && [ "$u" = "$(cfg DEFAULT_USER)" ] || exit 1
    printf '%s\t%s\n' "$u" "$p" ;;
  mac)
    # the MAC address of the PC learnt after a connection (kiosk.sh), for Wake-on-LAN when WAKE_MAC is empty
    h=$2; m=$(echo "$3" | tr 'A-F' 'a-f')
    [[ $h =~ ^[A-Za-z0-9][A-Za-z0-9.:-]{0,252}$ ]] && [[ $m =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ ]] || exit 1
    [ "$(cat "$OTR_LIB/wake/$h" 2>/dev/null)" = "$m" ] && exit 0
    install -d "$OTR_LIB/wake"; echo "$m" > "$OTR_LIB/wake/$h"; ev "Wake-on-LAN: MAC address of $h learnt ($m)" ;;
  forget)
    f=${OTR_SECRET_FILES[rdp-login]}
    [ -e "$f" ] || [ -e "$OTR_SEALED/rdp-login.cred" ] || exit 0
    rm -f "$f" "$OTR_SEALED/rdp-login.cred" "$OTR_SECRETS/rdp-login"; ev "remembered password forgotten" ;;
  *) echo "usage: remember.sh store USER | get | mac HOST MAC | forget" >&2; exit 2 ;;
esac
