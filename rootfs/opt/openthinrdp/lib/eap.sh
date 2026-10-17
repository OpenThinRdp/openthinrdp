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

# wifi_saved_psk SSID: the WPA key in the Wi-Fi configuration, when it is for that network
wifi_saved_psk(){
  local w; w=$(secret_path wifi.conf)
  grep -qF "ssid=\"$1\"" "$w" 2>/dev/null && sed -n 's/^[[:space:]]*psk=//p' "$w" | head -1
}

# wifi_conf_update [KEY]: the Wi-Fi configuration of wpa_supplicant from the settings, kept as a secret (lib/secrets.sh):
#   WIFI_SECURITY=psk     WPA2-Personal with KEY (64 hex), or the key saved for the same network
#   WIFI_SECURITY=peap|tls WPA2- and WPA3-Enterprise (WPA-EAP, WPA-EAP-SHA256 with management frame protection when
#                         the access point offers it) with the EAP settings; nothing written while they are incomplete
# Written only when it changes; wpa_supplicant reads it again at once.
wifi_conf_update(){
  local ssid sec key t c wl
  ssid=$(cfg WIFI_SSID); sec=$(cfg WIFI_SECURITY); key=$1
  [ -n "$ssid" ] || return 0
  t=$(mktemp); chmod 600 "$t"
  { echo "ctrl_interface=/run/wpa_supplicant"; c=$(cfg WIFI_COUNTRY); [ -n "$c" ] && echo "country=$c"
    case "$sec" in
      peap|tls)
        [ -z "$(eap_missing "$sec")" ] || { rm -f "$t"; return 0; }
        printf 'network={\n\tssid="%s"\n\tkey_mgmt=WPA-EAP WPA-EAP-SHA256\n\tieee80211w=1\n' "$ssid"
        eap_block "$sec"; printf '}\n' ;;
      *)
        [ -n "$key" ] || key=$(wifi_saved_psk "$ssid")
        [ -n "$key" ] || { rm -f "$t"; return 0; }
        printf 'network={\n\tssid="%s"\n\tpsk=%s\n\tkey_mgmt=WPA-PSK\n\tieee80211w=1\n}\n' "$ssid" "$key" ;;
    esac; } > "$t"
  [ -s "$t" ] || { rm -f "$t"; return 0; }
  if cmp -s "$t" "$(secret_path wifi.conf)"; then rm -f "$t"; return 0; fi
  mkdir -p /etc/wpa_supplicant
  secret_store wifi.conf "$t"
  wl=$(ls /sys/class/net 2>/dev/null | grep -E '^wl' | head -1)
  [ -n "$wl" ] && wpa_cli -p /run/wpa_supplicant -i "$wl" reconfigure >/dev/null 2>&1
  return 0
}
