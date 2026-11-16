# 802.1X (EAP): the settings shared by the cable (DOT1X=peap|tls, dot1x.sh) and the Wi-Fi (WIFI_SECURITY=peap|tls).
# Source it after common.sh and secrets.sh: . /opt/openthinrdp/lib/eap.sh   (root, but for eap_ca_file and eap_mode)
# ONE block of settings for both: the same account (PEAP) or the same certificate (EAP-TLS) on the cable and on the
# Wi-Fi, as a Windows PC does with its machine or user credentials. A network that wants two different identities is
# rare enough not to double every setting.
# - PEAP-MSCHAPv2: EAP_IDENTITY and its password, a secret (eap-password: TPM or root-only file, never in the settings).
# - EAP-TLS: the client certificate ($EAP_CERT, public) and its private key (eap-client.key, a secret whose path stays
#   the same also when it is kept in the TPM: the Wi-Fi configuration points to it), both sent by the manager over SSH.
# - The server is checked against EAP_CA (system = the system trust store, which also holds the CAs of the site in
#   /etc/openthinrdp/ca; or one .crt file of that folder) and EAP_SERVER_NAME (domain_suffix_match).
EAP_DIR=$OTR_ETC/dot1x
EAP_CERT=$EAP_DIR/client.crt
EAP_KEY=${OTR_SECRET_FILES[eap-client.key]}
EAP_SYSTEM_CA=/etc/ssl/certs/ca-certificates.crt
# what an identity may hold (EAP_IDENTITY, EAP_ANONYMOUS; the same rule in save-config.sh and the manager):
# EXAMPLE\user, user@example.com, host/pc1.example.com, a computer account with its $
EAP_IDRE='^[A-Za-z0-9._@\\/$ +-]{1,253}$'

# eap_ca_file: the CA file that must have signed the certificate of the RADIUS server
eap_ca_file(){ local c; c=$(cfg EAP_CA); case "$c" in ''|system) echo "$EAP_SYSTEM_CA" ;; *) echo "$OTR_ETC/ca/$c" ;; esac; }

# eap_identity MODE: the identity sent to the server. EAP-TLS without EAP_IDENTITY: the common name of the certificate
# (host/pc1.example.com, or the user principal name, as AD CS issues them)
eap_identity(){
  local id; id=$(cfg EAP_IDENTITY)
  if [ -z "$id" ] && [ "$1" = tls ] && [ -s "$EAP_CERT" ]; then
    id=$(openssl x509 -in "$EAP_CERT" -noout -subject -nameopt utf8,sep_multiline 2>/dev/null | sed -n 's/^[[:space:]]*CN=//p' | head -1)
  fi
  echo "$id"
}

# eap_missing MODE: what MODE (peap|tls) still lacks, one line in English; nothing = complete. Missing pieces are no
# error of the settings (the password or the certificate come later, from the manager): the device says what is missing
eap_missing(){
  local ca; ca=$(eap_ca_file)
  [ -s "$ca" ] || { echo "CA $(cfg EAP_CA) not found in $OTR_ETC/ca"; return; }
  case "$1" in
    peap)
      [ -n "$(cfg EAP_IDENTITY)" ] || { echo "no identity (EAP_IDENTITY)"; return; }
      [ -s "$(secret_path eap-password)" ] || { echo "no password (EAP_PASSWORD, or 802.1X... in the manager)"; return; } ;;
    tls)
      { [ -s "$EAP_CERT" ] && [ -s "$EAP_KEY" ]; } || { echo "no client certificate (802.1X... in the manager)"; return; }
      [ -n "$(eap_identity tls)" ] || { echo "no identity (EAP_IDENTITY, or a certificate with a common name)"; return; } ;;
  esac
}

# eap_warning: what the status says when the server is not checked by name: any server with a certificate of EAP_CA
# (with "system", any public certificate) would get the password, or would be trusted as the network
eap_warning(){ [ -n "$(cfg EAP_SERVER_NAME)" ] || echo "WARNING: EAP_SERVER_NAME empty, any server with a certificate signed by EAP_CA ($(cfg EAP_CA)) is trusted"; }

# eap_block MODE: the EAP lines of a wpa_supplicant network block. The password goes as hex: any character, nothing
# to escape. PEAP: MSCHAPv2 inside, as Windows NPS and FreeRADIUS do for domain accounts.
eap_block(){
  local a n p
  if [ "$1" = tls ]; then printf '\teap=TLS\n'; else printf '\teap=PEAP\n'; fi
  # the identity as written, or as hex when it holds a character the configuration file could take otherwise (the
  # common name of a certificate may have anything)
  a=$(eap_identity "$1")
  if [[ $a =~ $EAP_IDRE ]]; then printf '\tidentity="%s"\n' "$a"
  else printf '\tidentity=%s\n' "$(printf '%s' "$a" | od -An -v -tx1 | tr -d ' \n')"; fi
  a=$(cfg EAP_ANONYMOUS); [ -n "$a" ] && printf '\tanonymous_identity="%s"\n' "$a"
  printf '\tca_cert="%s"\n' "$(eap_ca_file)"
  # one or more names, the certificate of the server must be for one of them or a name under it
  n=$(cfg EAP_SERVER_NAME); [ -n "$n" ] && printf '\tdomain_suffix_match="%s"\n' "${n// /;}"
  if [ "$1" = tls ]; then
    printf '\tclient_cert="%s"\n\tprivate_key="%s"\n' "$EAP_CERT" "$EAP_KEY"
  else
    p=$(head -1 "$(secret_path eap-password)" 2>/dev/null)
    printf '\tpassword=%s\n' "$(printf '%s' "$p" | od -An -v -tx1 | tr -d ' \n')"
    printf '\tphase2="auth=MSCHAPV2"\n'
  fi
}

# a network name in hex (any character is safe in the file of wpa_supplicant) and back
wifi_hex(){ printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n'; }   # -v: od folds repeated lines into "*" (soso192)
wifi_unhex(){ printf "$(printf '%s' "$1" | sed 's/../\\x&/g')"; }

# wifi_saved_psk SSID: the WPA key of that network in the Wi-Fi configuration (named in clear or in hex)
wifi_saved_psk(){
  local w; w=$(secret_path wifi.conf)
  awk -v q="ssid=\"$1\"" -v x="ssid=$(wifi_hex "$1")" '
    { l = $0; gsub(/^[ \t]+/, "", l) }
    l ~ /^network=\{/ { s = 0; p = "" }
    l == q || l == x { s = 1 }
    l ~ /^psk=/ { p = substr(l, 5) }
    l == "}" { if (s && p != "") { print p; exit } }' "$w" 2>/dev/null
}

# The networks this device keeps by itself (0.3.6): the ones joined from the Wi-Fi page while another one is the main
# network of the settings. A secret like the Wi-Fi file (wifi-known): "<name in hex>\t<key in hex>" per line, the last
# joined first, WIFI_KNOWN_MAX at most. They are the user's: the central settings never touch them.
WIFI_KNOWN_MAX=10
wifi_known(){ local f; f=$(secret_path wifi-known); [ -s "$f" ] && grep -E $'^[0-9a-f]+\t[0-9a-f]{64}$' "$f"; }
wifi_known_names(){ local h k; wifi_known | while IFS=$'\t' read -r h k; do wifi_unhex "$h"; echo; done; }
# the list from stdin becomes the secret (an empty one removes it)
wifi_known_store(){
  local t; t=$(mktemp); chmod 600 "$t"; cat > "$t"
  if [ -s "$t" ]; then secret_store wifi-known "$t"
  else rm -f "$t" "$OTR_SEALED/wifi-known.cred" "$OTR_SECRETS/wifi-known" "${OTR_SECRET_FILES[wifi-known]}"; fi
}
wifi_known_add(){ local h; h=$(wifi_hex "$1"); { printf '%s\t%s\n' "$h" "$2"; wifi_known | awk -F'\t' -v h="$h" '$1 != h'; } | head -n $WIFI_KNOWN_MAX | wifi_known_store; }
wifi_known_forget(){ local h; h=$(wifi_hex "$1"); wifi_known | awk -F'\t' -v h="$h" '$1 != h' | wifi_known_store; }

# wifi_conf_update [KEY]: the Wi-Fi configuration of wpa_supplicant, kept as a secret (lib/secrets.sh), with
#   the main network (WIFI_SSID):
#     WIFI_SECURITY=psk      WPA2-Personal with KEY (64 hex), or the key saved for the same network
#     WIFI_SECURITY=peap|tls WPA2- and WPA3-Enterprise (WPA-EAP, WPA-EAP-SHA256 with management frame protection when
#                            the access point offers it) with the EAP settings
#   the other networks of the settings (WIFI_SSID_2..4, WPA2-Personal): their new key in WIFI_NEWKEY[n] (save-config.sh)
#     or the one saved; a network without a key is left out
#   the networks of the device (wifi_known), but the ones above
# wpa_supplicant joins by itself whichever of them is around, the strongest when more are. The main network set but not
# usable (enterprise settings incomplete, its key not readable: #201) leaves the file as it is, unless the device's own
# networks just changed (WIFI_FORCE=1, wifi.sh). Written only when it changes; wpa_supplicant reads it again at once.
wifi_conf_update(){
  local ssid sec key t c wl n s k h body="" missing="" names
  ssid=$(cfg WIFI_SSID); sec=$(cfg WIFI_SECURITY); key=$1; names=" $(wifi_hex "$ssid") "
  if [ -n "$ssid" ]; then
    case "$sec" in
      peap|tls)
        if [ -z "$(eap_missing "$sec")" ]; then
          body+="$(printf 'network={\n\tssid="%s"\n\tkey_mgmt=WPA-EAP WPA-EAP-SHA256\n\tieee80211w=1\n' "$ssid"; eap_block "$sec"; printf '}')"$'\n'
        else missing=1; fi ;;
      *)
        [ -n "$key" ] || key=$(wifi_saved_psk "$ssid")
        if [ -n "$key" ]; then body+="$(printf 'network={\n\tssid="%s"\n\tpsk=%s\n\tkey_mgmt=WPA-PSK\n\tieee80211w=1\n}' "$ssid" "$key")"$'\n'
        else missing=1; fi ;;
    esac
  fi
  for n in 2 3 4; do
    s=$(cfg WIFI_SSID_$n); h=$(wifi_hex "$s")
    [ -n "$s" ] && [[ $names != *" $h "* ]] || continue
    k=${WIFI_NEWKEY[$n]:-}; [ -n "$k" ] || k=$(wifi_saved_psk "$s"); [ -n "$k" ] || continue
    names+="$h "; body+="$(printf 'network={\n\tssid=%s\n\tpsk=%s\n\tkey_mgmt=WPA-PSK\n\tieee80211w=1\n}' "$h" "$k")"$'\n'
  done
  while IFS=$'\t' read -r h k; do
    [ -n "$h" ] && [[ $names != *" $h "* ]] || continue
    names+="$h "; body+="$(printf 'network={\n\tssid=%s\n\tpsk=%s\n\tkey_mgmt=WPA-PSK\n\tieee80211w=1\n}' "$h" "$k")"$'\n'
  done < <(wifi_known)
  [ -n "$missing" ] && [ -z "${WIFI_FORCE:-}" ] && return 0
  # nothing to write, unless the last network of the device was just forgotten (an empty list of networks then)
  [ -n "$body" ] || [ -n "${WIFI_FORCE:-}" ] || return 0
  t=$(mktemp); chmod 600 "$t"
  { echo "ctrl_interface=/run/wpa_supplicant"; c=$(cfg WIFI_COUNTRY); [ -n "$c" ] && echo "country=$c"; printf '%s' "$body"; } > "$t"
  if cmp -s "$t" "$(secret_path wifi.conf)"; then rm -f "$t"; return 0; fi
  mkdir -p /etc/wpa_supplicant
  secret_store wifi.conf "$t"
  wl=$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)
  [ -n "$wl" ] && wpa_cli -p /run/wpa_supplicant -i "$wl" reconfigure >/dev/null 2>&1
  return 0
}
