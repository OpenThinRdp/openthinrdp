# The secrets of the device: the password of the management folder account, the Wi-Fi key, the SSH host keys, the VPN
# key and profile, the 802.1X password and the private key of the 802.1X certificate.
# Source it after common.sh: . /opt/openthinrdp/lib/secrets.sh   (root only)
# With a TPM 2.0 (and TPM_SECRETS=on, the default) they are kept encrypted with a key that never leaves the TPM
# (systemd-creds, --with-key=tpm2, no PCRs: a firmware update or a Secure Boot change does not lose them) in
# $OTR_SEALED, and decrypted at every start into $OTR_SECRETS, in memory (secrets.sh, before the network and SSH). A
# disk or eMMC taken out of the device gives nothing. Without a TPM, or with TPM_SECRETS=off, they stay in root-only
# files where they always were.
# The folder password and the Wi-Fi key keep their usual path, a link to the copy in memory: nothing that reads them
# (the network configuration above all) changes. The SSH host keys are given to sshd through a drop-in.
OTR_SEALED=$OTR_ETC/sealed
OTR_SECRETS=/run/openthinrdp/secrets
# name -> where the file lives without a TPM
declare -A OTR_SECRET_FILES=(
  [smb.cred]=$OTR_ETC/smb.cred
  [wifi.conf]=/etc/wpa_supplicant/openthinrdp-wifi.conf
  [ssh_host_ed25519_key]=/etc/ssh/ssh_host_ed25519_key
  [ssh_host_ecdsa_key]=/etc/ssh/ssh_host_ecdsa_key
  [ssh_host_rsa_key]=/etc/ssh/ssh_host_rsa_key
  [vpn-wg.key]=$OTR_ETC/vpn/wg.key
  [vpn-openvpn.conf]=$OTR_ETC/vpn/openvpn.conf
  [vpn-openvpn.auth]=$OTR_ETC/vpn/openvpn.auth
  [eap-password]=$OTR_ETC/dot1x/password
  [eap-client.key]=$OTR_ETC/dot1x/client.key
)
# the key of the 802.1X certificate keeps its path too: the Wi-Fi configuration (itself a secret) names it
OTR_SECRET_LINKED="smb.cred wifi.conf eap-client.key"

# a TPM 2.0 that systemd can use: firmware, driver, device and the tss2 libraries ("partial" = exit 16 = no)
secret_tpm(){ command -v systemd-creds >/dev/null && systemd-analyze has-tpm2 >/dev/null 2>&1; }
# TPM_SECRETS: the central settings first (the last copies report.sh keeps, already there before the update that
# brings this in), then the device's. At the first start after the update the central value counts already, before
# the central settings are applied: a folder that says off keeps every device out of the TPM from the start.
secret_setting(){ local f v
  for f in "$OTR_LIB/central-host.conf" "$OTR_LIB/central-common.conf"; do
    v=$(sed '1s/^\xEF\xBB\xBF//' "$f" 2>/dev/null | tr -d '\r' | sed -nE 's/^[[:space:]]*TPM_SECRETS[[:space:]]*=[[:space:]]*([A-Za-z0-9]*).*/\1/p' | head -1)
    [ -n "$v" ] && break
  done
  [ -n "$v" ] || v=$(cfg TPM_SECRETS)
  case "$(echo "$v" | tr 'A-Z' 'a-z')" in off|no|false|0) echo off ;; *) echo on ;; esac
}
# the secrets go into the TPM: there is one and TPM_SECRETS is not off
secret_enabled(){ [ "$(secret_setting)" != off ] && secret_tpm; }
secret_sealed(){ [ -s "$OTR_SEALED/$1.cred" ]; }
secret_linked(){ [[ " $OTR_SECRET_LINKED " == *" $1 "* ]]; }

# secret_path NAME: the file to read the secret from (the copy in memory, or the plain file). It may not exist.
secret_path(){
  if secret_sealed "$1"; then
    [ -s "$OTR_SECRETS/$1" ] || secret_unseal "$1"
    echo "$OTR_SECRETS/$1"
  else echo "${OTR_SECRET_FILES[$1]}"; fi
}

# secret_unseal NAME: decrypt into memory. 1 = the TPM does not give it back (another TPM, TPM cleared)
secret_unseal(){
  install -d -m 700 "$OTR_SECRETS"
  ( umask 077; systemd-creds decrypt --name="$1" "$OTR_SEALED/$1.cred" "$OTR_SECRETS/$1.new" >/dev/null 2>&1 ) || {
    rm -f "$OTR_SECRETS/$1.new"; return 1; }
  mv -f "$OTR_SECRETS/$1.new" "$OTR_SECRETS/$1"
}

# secret_link NAME: the usual path of a linked secret points to the copy in memory (a plain file there is replaced)
secret_link(){
  local p=${OTR_SECRET_FILES[$1]}
  secret_linked "$1" || return 0
  [ "$(readlink "$p" 2>/dev/null)" = "$OTR_SECRETS/$1" ] && return 0
  install -d "$(dirname "$p")"; rm -f "$p"; ln -s "$OTR_SECRETS/$1" "$p"
}

# secret_plain NAME FILE: FILE becomes the plain file again (root 600), no copy in the TPM
secret_plain(){
  local p=${OTR_SECRET_FILES[$1]}
  install -d "$(dirname "$p")"; rm -f "$p"; chmod 600 "$2"; mv -f "$2" "$p"
  rm -f "$OTR_SEALED/$1.cred" "$OTR_SECRETS/$1"
}

# secret_store NAME FILE: FILE (new content) becomes the secret; FILE is consumed. Into the TPM when enabled: the
# encrypted copy is read back and compared first, and only then the plain file goes. Otherwise the plain file.
secret_store(){
  local n=$1 f=$2 c
  if secret_enabled; then
    install -d -m 700 "$OTR_SEALED" "$OTR_SECRETS"; c=$(mktemp)
    if systemd-creds encrypt --with-key=tpm2 --tpm2-pcrs= --name="$n" "$f" "$OTR_SEALED/$n.cred.new" >/dev/null 2>&1 &&
       systemd-creds decrypt --name="$n" "$OTR_SEALED/$n.cred.new" "$c" >/dev/null 2>&1 && cmp -s "$f" "$c"; then
      rm -f "$c"; chmod 600 "$OTR_SEALED/$n.cred.new"; mv -f "$OTR_SEALED/$n.cred.new" "$OTR_SEALED/$n.cred"
      install -m 600 "$f" "$OTR_SECRETS/$n"; rm -f "$f"
      if secret_linked "$n"; then secret_link "$n"; else rm -f "${OTR_SECRET_FILES[$n]}"; fi
      return 0
    fi
    rm -f "$c" "$OTR_SEALED/$n.cred.new"
    ev "secret $n: the TPM did not give it back correctly, kept in a root-only file"
  fi
  secret_plain "$n" "$f"
}

# secret_sshd_hostkeys: sshd reads the host keys kept in the TPM from memory, through a drop-in that must be in place
# before ssh starts (secrets.sh at boot, apply.sh when it creates new keys). 0 = the drop-in changed
secret_sshd_hostkeys(){
  local f=/etc/ssh/sshd_config.d/00-openthinrdp-hostkeys.conf k l=""
  for k in ed25519 ecdsa rsa; do secret_sealed ssh_host_${k}_key && l="${l}HostKey $(secret_path ssh_host_${k}_key)\n"; done
  if [ -z "$l" ]; then [ -e "$f" ] || return 1; rm -f "$f"; return 0; fi
  mkdir -p "$(dirname "$f")"
  printf "# OpenThinRDP (lib/secrets.sh): the host keys are kept in the TPM and read from memory\n$l" > "$f.new"
  if cmp -s "$f.new" "$f"; then rm -f "$f.new"; return 1; fi
  mv -f "$f.new" "$f"
}

# secret_mode: what the status file reports
secret_mode(){
  local n
  for n in "${!OTR_SECRET_FILES[@]}"; do secret_sealed "$n" && { echo tpm; return; }; done
  if [ "$(secret_setting)" = off ]; then echo "file (TPM_SECRETS=off)"
  elif secret_tpm; then echo "tpm (nothing stored yet)"; else echo "file (no TPM)"; fi
}
