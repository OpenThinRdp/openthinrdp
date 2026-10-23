# Configuration

Every setting is a `KEY=value` line. A device reads them in this order, the first file that has the key wins:

1. `/etc/openthinrdp/openthinrdp.conf`: this device (settings dialog ⚙, central settings)
2. `/etc/openthinrdp/site.conf`: your organization, built into the image from `image/site/site.conf`
3. `/opt/openthinrdp/defaults.conf`: project defaults

An empty value in a higher file clears a lower one on purpose (e.g. `TITLE=` in the device file).

The device file is written by the settings dialog **and** by the central settings, and the central settings
win: in practice the order is `config\<hostname>.conf` > `config\common.conf` > settings dialog > `site.conf` >
defaults. A key removed from the central files goes back to `site.conf`/defaults, so all devices stay alike
(see [management.md](management.md)).
Values are validated by `save-config.sh` with the same rules wherever they come from (dialog, central
settings, manager); invalid central settings are refused as a whole and the previous ones stay.

The reference with comments is [`rootfs/opt/openthinrdp/defaults.conf`](../rootfs/opt/openthinrdp/defaults.conf).

## Remote desktop

| Key | Default | Meaning |
|---|---|---|
| `BROKER` | | RD Connection Broker, or directly a session host or any Windows PC with Remote Desktop on: name or IP. Empty = the settings dialog opens at start |
| `BROKER_FALLBACK` | | other brokers, space separated, tried in turn from the 3rd attempt |
| `DOMAIN` | | Windows domain of the users |
| `LOAD_BALANCE_INFO` | | RDS collection, as `loadbalanceinfo` in the .rdp file, e.g. `tsv://VMResource.1.VDI` |
| `DEFAULT_USER` | | user name pre-filled in the sign-in form |
| `TRANSPORT` | `auto` | `auto` = UDP, TCP when UDP is blocked or fails; `udp` = UDP only; `tcp` = TCP only. See [udp.md](udp.md) |
| `RDP_AUTH` | `negotiate` | `negotiate` = Kerberos, NTLM when Kerberos is not available (`DOMAIN` must be the full DNS name, e.g. `example.local`); `kerberos` = Kerberos only: the sign-in fails instead of falling back to NTLM (for domains that turned NTLM off, and to see a broken Kerberos setup at once); `ntlm` = NTLM only. Behind an alias shared by several brokers the device connects to one of them by its own name, so that the Kerberos ticket is for the server it talks to |
| `RDP_CERT` | `tofu` | `ignore`, `tofu` (trust on first use) or `verify` |
| `RDP_GATEWAY` | | RD Gateway (Remote Desktop Gateway) for devices outside the office: `name[:port]`, 443 when no port. See [RD Gateway](#rd-gateway) |
| `RDP_GATEWAY_USE` | `always` | `always` = every connection through the gateway; `detect` = a server on the local network straight, the others through the gateway |
| `RDP_GFX` | `progressive,AVC420:off,AVC444:off` | `/gfx` options. Without a GPU on the server this keeps text pixel exact |
| `RDP_KEYBOARD` | | keyboard layout id for Windows, e.g. `0x00000409`. Empty = taken from the X keyboard |
| `MULTIMON` | `auto` | `auto` = every monitor when more than one is connected (`/multimon`), `off` = only the main one |
| `RDP_EXTRA` | | extra xfreerdp3 options (letters, digits, `/:+,._=#-` and spaces only) |
| `SESSION_THRESHOLD` | `10` | a session that ends within these seconds counts as a failed attempt |
| `SHUTDOWN_SECS` | `10` | after the user disconnects, switch off after these seconds (0 = never) |

The device switches off only after a deliberate end (disconnect, sign out, VM shut down by an administrator).
Every other ending (network drop, crash, server restart) reconnects without asking. A session taken over by
another device shows "Session opened elsewhere" with *Resume here* instead of reconnecting. When the broker
answers but the virtual machine refuses the desktop (it is restarting or installing a Windows update), the device
shows *Waiting for Windows* with a Cancel button and tries again every 20 s, without counting attempts, for up to
20 minutes.

### RD Gateway

A device in a branch office or at home reaches the RDS deployment through its **RD Gateway**, the role that
carries RDP over HTTPS (port 443), so that nothing but 443 is published on the Internet. Set `RDP_GATEWAY` to its
public name, e.g. in `config\<hostname>.conf` of the devices that are outside, or in `common.conf` with
`RDP_GATEWAY_USE=detect` for devices that move:

```
RDP_GATEWAY=rdgateway.example.com
```

- The broker and, after its redirect, the virtual machine are reached through the gateway with the **credentials of
  the session**: the user signs in once. Who may connect, and to which servers, is decided by the policies of the
  gateway (RD CAP and RD RAP).
- **TCP through the gateway.** FreeRDP carries no UDP through a gateway (its UDP transport, port 3391, is not
  implemented). With `detect`, a server reached straight on the local network keeps UDP (since 0.1.15; before, UDP
  was declined as soon as a gateway was set). `TRANSPORT=udp` is not enforced with a gateway. `/network:auto` stays:
  the server adapts frame rate and image quality to the line.
- **Certificate.** The gateway presents its HTTPS certificate: with `RDP_CERT=verify` it must be trusted by the device
  (a public certificate, or your CA in the `ca/` folder of the site files).
- **Kerberos** needs the domain controllers: outside the office, with no KDC proxy, use `RDP_AUTH=negotiate` (NTLM
  when Kerberos cannot be reached) or `ntlm`.
- The diagnostics of the device (settings, *Diagnostics*) test the gateway on its port instead of the brokers on
  3389. A session that the server closes with code 1 counts as ended: through a gateway the device cannot ask the
  virtual machine whether it still runs.

## USB

| Key | Default | Meaning |
|---|---|---|
| `USB_MODE` | `all` | `all` = every device except keyboard, mouse, touch screen, hub, Bluetooth adapter, network adapter, smart card reader, webcam and USB headset goes to Windows as a whole device (RemoteFX USB redirection). `disks` = USB sticks stay on the thin client, are mounted there and appear in Windows as redirected drives (`\\tsclient`), also when plugged in during a session (since 0.1.7). `auto` = device by device: a device that is only storage (every interface mass storage: a stick, a card reader, a disk) as a drive, as with `disks`; a device with storage and something else (an instrument with a serial port, a key with its own Windows driver) whole, as with `all`, so that its driver gets all of it. Plugged in during a session, `auto` works as `disks`: FreeRDP's filter sees a class on any interface |
| `USB_REDIRECT` | | `VID:PID` list always passed whole, in every mode (smart card readers excepted: they always go through the smart card channel) |

A USB stick passed whole (`USB_MODE=all`) gets its drive letter from Windows inside the session of the user it is
redirected to, as on a physical PC. That letter is not visible to services or to other sessions, so a tool running
as SYSTEM sees no letter: this is how Windows works, not something to fix by assigning letters.

Webcams and USB sound devices (headsets, speakerphones) stay on the thin client: the camera goes through the RDP
camera channel and appears in Windows as "*name* (redirected)", the microphone and the speaker through the RDP
audio channels ("Remote Audio"). Passed as whole USB devices they reach Windows as devices of the console session,
and the apps of the remote session see no microphone at all. When there is no USB microphone the thin client's
own input is used. A device listed in `USB_REDIRECT` is still passed whole.

## Network

| Key | Default | Meaning |
|---|---|---|
| `NETMODE` | `dhcp` | `dhcp` or `static` |
| `IPADDR`, `NETMASK`, `GATEWAY` | | static address (static mode only) |
| `DNS1`, `DNS2` | | DNS servers; empty = from DHCP. Required with a static address |
| `NTP` | | time servers; empty = Debian pool |
| `HOSTNAME` | `thinclient-` + the last 6 digits of the MAC address | name of the device (the system host name, not stored in the settings file) |
| `WIFI` | `off` | `on` = use Wi-Fi when no cable is connected |
| `WIFI_SSID`, `WIFI_COUNTRY` | | network name, regulatory country (two letters) |
| `WIFI_PSK` | | password or 64-hex key. Only in central settings or the dialog; stored only in `/etc/wpa_supplicant` |
| `WIFI_SECURITY` | `psk` | `psk` = a password (WPA2-Personal, `WIFI_PSK`); `peap` or `tls` = WPA2/WPA3-Enterprise with the 802.1X settings below. See [802.1X and Wi-Fi Enterprise](#8021x-and-wi-fi-enterprise) |
| `DOT1X` | `off` | 802.1X on the cable: `peap` (an account and its password) or `tls` (a certificate of the device). See [802.1X and Wi-Fi Enterprise](#8021x-and-wi-fi-enterprise) |
| `EAP_IDENTITY` | | the identity: `DOMAIN\user`, `user@domain`, `host/name.domain`. With `tls`, empty = the common name of the certificate |
| `EAP_ANONYMOUS` | | outer identity, sent in clear before the tunnel, e.g. `anonymous@example.com`. Empty = the identity |
| `EAP_CA` | `system` | the authority that signed the certificate of the RADIUS server: `system` (the system trust store, with the CAs of the site) or the name of a `.crt` file in `/etc/openthinrdp/ca` |
| `EAP_SERVER_NAME` | | name(s) the certificate of the RADIUS server must be for (or a name under them), space separated. Always set it |
| `EAP_PASSWORD` | | the PEAP password. Only in the dialog, the central settings or sent by the manager; stored only as a secret of the device |
| `VPN` | `off` | `wireguard` or `openvpn`: the device's own VPN, for devices outside the office. See [VPN](#vpn) |
| `VPN_SERVER`, `VPN_SERVER_KEY` | | WireGuard: the server, `name[:port]` (51820 when no port), and its public key |
| `VPN_ADDRESS` | | WireGuard: the address of this device in the tunnel with its prefix, e.g. `10.8.0.15/24`. One per device: ignored in `common.conf` |
| `VPN_ROUTES` | | networks of the office through the tunnel (CIDR, space separated); empty = all the traffic (WireGuard). With OpenVPN, added to the routes the server pushes |
| `VPN_DNS` | | DNS servers of the office, in front of the others while the tunnel is up. Empty: WireGuard keeps the DNS it has, OpenVPN takes the ones the server pushes |

### VPN

The other way for a device outside the office: its own tunnel to the office network, WireGuard or OpenVPN. Through
it go the broker, the management folder (status, central configuration, updates) and the DNS of the office, so the
device works as it does inside. Compared with the [RD Gateway](#rd-gateway): no gateway server to publish, and inside
WireGuard the session **keeps UDP**; a VPN server is needed instead, often the firewall of the office.

**WireGuard**, set in the manager or in the configuration files:

```
# config\common.conf
VPN=wireguard
VPN_SERVER=vpn.example.com
VPN_SERVER_KEY=<public key of the server>
VPN_ROUTES=192.168.0.0/23
VPN_DNS=192.168.1.10

# config\<hostname>.conf
VPN_ADDRESS=10.8.0.15/24
```

- The **private key is made on the device** at the first start with `VPN=wireguard` and never leaves it (a secret,
  in the TPM when there is one). Its public key is in the status report (`VPN_PUBLIC_KEY`); in the manager, the
  Summary of the device shows it, and a double click or Ctrl+C on that row copies the `[Peer]` block to add on the
  server (the public key and `AllowedIPs` = the address of the device /32). Until the server knows it, the state
  says *no answer from the server yet*.
- `VPN_ROUTES` empty sends **all the traffic** through the tunnel: the server itself stays on the local way, the
  default route of the local network stays and is used again as soon as the tunnel goes.
- A server name is resolved again when the tunnel stays silent for 3 minutes (a dynamic address). The tunnel sends a
  keepalive every 25 s, so that a NAT router at home keeps it open.

**OpenVPN**: `VPN=openvpn`, and the profile of the device (the `.ovpn` file the VPN provider or the firewall gives)
sent from the manager with **VPN profile...** (device header, shown when `VPN=openvpn`), with the user and password
when the profile asks for them (`auth-user-pass`).

- Profile and password go **over SSH** with the key of the vault (`SSH=on` on the device) and are secrets of the
  device: they never go through the management folder, which every device can read, and never on a command line.
  The profile is refused when it would run commands or write files (`script-security`, `up`/`down`, `plugin`,
  `management`, `log`...): the scripts that run are the device's own.
- The tunnel restarts by itself when it drops. A **password the server refuses** is tried again only after an hour
  (or as soon as the manager sends new credentials): retried every few seconds, it would lock a domain account.
- DNS servers pushed by the server (`dhcp-option DNS`) are used unless `VPN_DNS` names others.

The state of the VPN is in the report (`VPN=`), in the manager (Summary, Network) and in the diagnostics of the
device. Events: *VPN: ...* in the event log.

### 802.1X and Wi-Fi Enterprise

Corporate networks often admit nothing on a switch port that has not authenticated with **802.1X**, and enterprise
Wi-Fi uses **WPA2/WPA3-Enterprise**, the same protocol over the air. The device does both with `wpa_supplicant`:

- `DOT1X=peap` or `tls`: 802.1X on every wired adapter (`dot1x.sh`, one `openthinrdp-dot1x@<adapter>` service each,
  `wpa_supplicant -D wired`).
- `WIFI_SECURITY=peap` or `tls`: the Wi-Fi network of `WIFI_SSID` as WPA2- or WPA3-Enterprise.
- **One block of EAP settings serves both**: the same account (PEAP) or the same certificate (EAP-TLS) on the cable
  and on the Wi-Fi, as a Windows PC uses the same credentials for both. A network that wants a different identity on
  each is rare enough not to double every setting.

Two methods, the ones Windows NPS and FreeRADIUS offer for domain devices:

| | PEAP (`peap`) | EAP-TLS (`tls`) |
|---|---|---|
| Who authenticates | an account and its password (PEAP-MSCHAPv2) | a certificate of the device and its private key |
| Where the secret comes from | the settings dialog (*802.1X password*), `EAP_PASSWORD` in the central settings, or the manager (**802.1X...**, over SSH) | the manager (**802.1X...**, over SSH): a `.pfx` as Windows exports it, or a PEM certificate and its key |
| Identity | `EAP_IDENTITY`, e.g. `EXAMPLE\svc-thin-8021x` | `EAP_IDENTITY`, or empty = the common name of the certificate |

```
# config\common.conf: every device on 802.1X ports with one service account (PEAP)
DOT1X=peap
EAP_IDENTITY=EXAMPLE\svc-thin-8021x
EAP_ANONYMOUS=anonymous@example.com
EAP_CA=corp-root.crt
EAP_SERVER_NAME=nps.example.com
```

**The server is always checked.** The device sends nothing secret before the RADIUS server has shown a certificate
signed by `EAP_CA` and made out to `EAP_SERVER_NAME` (or a name under it, `domain_suffix_match`); a server that fails
either check is refused (*certificate of the server not accepted: ...*) and the password never leaves the device.
`EAP_CA=system` trusts the system store, which holds the public authorities **and** the authorities of your site
(`ca/*.crt` of the site files, `/etc/openthinrdp/ca`); a file name (e.g. `corp-root.crt`, from that folder) trusts that
authority only. **Set `EAP_SERVER_NAME` always**: without it any server with a certificate of `EAP_CA`, with `system`
any server with a public certificate, would get the password; the status of the device says so with a WARNING, and the
manager notes it when the settings are saved.

**On the cable**, in the order things happen:

1. The adapter comes up (boot, cable plugged in, settings changed): its supplicant starts **before** the address is
   asked (a `pre-up` of the adapter), and DHCP (or the static address) waits for the authentication, 40 s at most.
2. **Authenticated**: the port is open, DHCP goes on. When the port was authenticated after the address was already
   asked (a supplicant restarted, a switch that answered late), the address is asked again (`dhcpcd -n`): a switch may
   put an authenticated device in another VLAN than before.
3. **Refused**: DHCP goes on too, for the network the switch gives a refused device (a guest or restricted VLAN, or
   none). The reason is in the state: *password refused by the server*, *certificate of the server not accepted:
   Domain suffix mismatch (...)*, *refused by the server (certificate, account or network policy)*.
   A **PEAP password the server refuses is not tried again for an hour**, or until a new one arrives (dialog, central
   settings, manager): switches ask again every minute, and a domain account would be locked.
4. **No authenticator**: a port that does not answer 802.1X at all (a switch without it, a desk at home) gets the
   network without it after 15 s, and the state says *no authenticator: DHCP without 802.1X*. A device set up for
   802.1X works on any switch; the supplicant keeps listening, and a switch that starts 802.1X later is answered.
5. **Cable out and in**: authenticated again (an EAPOL-Start of its own after 2 and 8 s, when the switch does not ask
   first), then the address again.

Missing pieces are no error of the settings (the password or the certificate come later, from the manager): the state
says *incomplete: no password* or *no client certificate*, and the network works without 802.1X meanwhile.

**Secrets.** The PEAP password and the private key of the certificate are secrets of the device, kept like the Wi-Fi
key: in the TPM when there is one (`TPM_SECRETS`), otherwise in root-only files; never in the settings files, never in
the status. The manager sends them with **802.1X...** in the header of a device (shown with `DOT1X` or an enterprise
Wi-Fi), over SSH with the key of the vault (`SSH=on`), on standard input: never through the management folder, which
every device can read. A certificate is checked twice, in the manager (the password of a `.pfx`, its private key, the
dates, the use for client authentication) and on the device with openssl (the key belongs to the certificate, not
expired); the key is kept **decrypted**, its password nowhere. `EAP_PASSWORD` in `common.conf` works too (compared by
its hash, applied once), but every device that reads the file can read it: per device, prefer the manager.

**Getting there the first time.** A device on a port that admits nothing without 802.1X has no network until it is set
up: type the PEAP settings in its settings dialog (section *802.1X*), or set it up first on a port without 802.1X, or
one with MAC authentication bypass or a guest VLAN that reaches the management folder. EAP-TLS needs the network once
anyway, for the manager to send the certificate.

**State and troubleshooting.** The report has `DOT1X=` (adapter by adapter: *authenticated (PEAP, server ...)*,
*failed: ...*, *no authenticator*, *incomplete: ...*, *no link*, or `off`), shown in the manager (Summary, Network) and
in the diagnostics of the device; `WIFI_STATUS` says *(802.1X PEAP)* or what is missing. Events: *802.1X: authenticated
on eth0 (...)*, *802.1X: failed on eth0: ...*, *802.1X: no authenticator on eth0 ...*. Everything the supplicant says:
`journalctl -u openthinrdp-dot1x@eth0` (SSH).

**Wi-Fi Enterprise** joins WPA2-Enterprise and WPA3-Enterprise networks (`WPA-EAP` and `WPA-EAP-SHA256`, protected
management frames when the access point offers or requires them), with the same EAP settings and the same checks of
the server. Not supported: WPA3-Enterprise 192-bit (Suite B), and WPA3-Personal (SAE) for `psk` networks. On Wi-Fi the
supplicant's own back-off applies to a refused password (10 s, then longer), not the hour of the cable.

#### Windows NPS: PEAP with domain accounts

1. Install the *Network Policy and Access Services* role and register the NPS server in Active Directory.
2. **Server certificate.** NPS needs a certificate for its name, e.g. `nps.example.com`, from your AD CS (the *RAS and
   IAS Server* template, autoenrollment for the NPS server), or any CA. Export the root CA as Base-64 (`.cer`), put it
   in the site files as `ca/corp-root.crt` (image or update package), and set `EAP_CA=corp-root.crt` (or `system`) and
   `EAP_SERVER_NAME=nps.example.com`.
3. **RADIUS clients**: the switches (and Wi-Fi controllers) with their address and shared secret.
4. **Network policy**: conditions *Windows Groups* = a group of the accounts the devices use, *NAS Port Type* =
   Ethernet (and Wireless - IEEE 802.11); constraints, *Authentication Methods*: **Microsoft: Protected EAP (PEAP)**,
   edited to use the server certificate above, with *Secured password (EAP-MSCHAP v2)* inside. Leave the other methods
   off. A refused device: the reason is in the NPS log (Event Viewer, *Network Policy Server*).
5. The device: `DOT1X=peap`, `EAP_IDENTITY=EXAMPLE\account` (a user account: a thin client has no domain computer
   password to use), its password with the manager or the dialog.

#### Windows NPS: EAP-TLS with certificates from AD CS

1. A **certificate template** for the devices: duplicate *Workstation Authentication* (or *User*), Enhanced Key Usage
   *Client Authentication*, *Allow private key to be exported*, subject from the request or built from Active Directory.
   Issue one certificate per device, e.g. for a computer account created for it, subject `CN=host/thin1.example.com`
   (and that name as DNS name in the subject alternative name), and export it with its private key as `.pfx`.
2. NPS maps the certificate to an account in Active Directory. With the *strong certificate mapping* that Windows
   enforces (KB5014754), give the certificate the security identifier of the account (issued by an enterprise CA for
   that account) or map it explicitly on the account (`altSecurityIdentities`), otherwise the mapping, and the
   authentication, may fail.
3. **Network policy** as for PEAP, with the authentication method **Microsoft: Smart Card or other certificate** (its
   server certificate as above).
4. The device: `DOT1X=tls`, `EAP_IDENTITY` empty (the common name of the certificate: `host/thin1.example.com`), and the
   `.pfx` with **802.1X...** in the manager.

#### FreeRADIUS

```
# clients.conf: each switch or Wi-Fi controller
client switches { ipaddr = 192.0.2.0/24  secret = <shared secret> }

# mods-available/eap, tls-config tls-common: the server certificate, and the CA of the device certificates (EAP-TLS)
private_key_file = ${certdir}/nps.example.com.key
certificate_file = ${certdir}/nps.example.com.crt
ca_file = ${cadir}/corp-root.crt

# mods-config/files/authorize: a local account for PEAP (or the mschap module with ntlm_auth for domain accounts)
svc-thin-8021x Cleartext-Password := "..."
```

PEAP-MSCHAPv2 and EAP-TLS are enabled in the default `eap` module; its first proposal (MD5) is declined by the device,
which asks for PEAP or TLS as set. The switch is a plain 802.1X authenticator with the FreeRADIUS server as its RADIUS
server.

Tested against hostapd (802.1X authenticator on a wired link, and a WPA2/WPA3-Enterprise access point on virtual
radios) with its own EAP server and with FreeRADIUS 3.2: PEAP and EAP-TLS, a wrong password (one try, then the hour),
a server of another CA or another name, no authenticator, the cable out and in.

### Desktops in the cloud

OpenThinRDP connects with RDP to any Windows it can reach, wherever it runs. An RDS deployment (broker, session
hosts or a VDI collection) or single Windows virtual machines in **Azure, AWS, Google Cloud** or with any other
provider are set up as on premises: `BROKER` is the broker or the machine, `LOAD_BALANCE_INFO` the collection.

- **How the devices reach it:** through the deployment's [RD Gateway](#rd-gateway) (HTTPS, the usual way to publish
  RDS in the cloud), through a [VPN](#vpn) to the cloud network (the device's own WireGuard or OpenVPN, or the
  site-to-site VPN of the office), or straight to a public address (not recommended: Remote Desktop open to the
  Internet).
- **UDP** works straight and through a VPN, as on premises: the firewall of the cloud network (security group, NSG)
  must let UDP 3389 in, besides TCP 3389. Through an RD Gateway the session uses TCP.
- **Sign-in** with the domain accounts of the deployment (Active Directory in the cloud, or a managed domain such as
  Microsoft Entra Domain Services), Kerberos or NTLM as on premises. Kerberos needs the domain controllers, so from
  outside with no VPN use `RDP_AUTH=negotiate` or `ntlm`.
- **Management folder:** an SMB share the devices can reach, usually on a file server through the VPN. Devices without
  a management folder work too, set up on the device (settings dialog) and updated from GitHub.
- **Not supported yet: Azure Virtual Desktop and Windows 365.** Their clients sign in with Microsoft Entra ID and
  connect through Microsoft's own gateway and broker, which the kiosk does not do (FreeRDP has experimental support,
  OpenThinRDP does not use it). Services with their own protocol (Citrix, Omnissa Horizon, Amazon WorkSpaces) are
  not RDP.

OpenThinRDP runs in production on premises; it is the same RDP in the cloud, but we have no cloud deployment of our
own to test on. Reports are welcome in the [Discussions](https://github.com/OpenThinRdp/openthinrdp/discussions).

## Management

| Key | Default | Meaning |
|---|---|---|
| `MGMT_SHARE` | | management folder, e.g. `\\fileserver\thinclients`, see [management.md](management.md); empty with a domain account (`MGMT_USER`): the folder the manager names for that account in the domain ([manager.md](manager.md#settings--manager-language-and-local-copy)) |
| `MGMT_USER` | | account of the management folder: `user`, `DOMAIN\user` or `user@domain`. Empty = `smb.cred` of the image |
| `MGMT_PASSWORD` | | its password. Only in central settings or the dialog; stored only in `/etc/openthinrdp/smb.cred` |
| `SECURITY_UPDATES` | `on` | Debian security updates, never FreeRDP, never a reboot |
| `ANON_STATS` | `on` | anonymous counts for the project (model, processor, memory, versions; never names or addresses), at the first start and then weekly; `off` = nothing is sent. See [privacy.md](privacy.md) |
| `TPM_SECRETS` | `on` | with a TPM 2.0: folder password, Wi-Fi key, SSH host keys, VPN and 802.1X secrets kept encrypted in it ([security.md](security.md)); `off` = root-only files, and back out of the TPM at the next start |
| `UPDATE_FROM` | `github` | OpenThinRDP software updates: `github` (signed releases, checked every 3 hours), `share` (`updates\` of the management folder) or `off`, see [management.md](management.md#signed-updates) |
| `UPDATE_GITHUB` | `OpenThinRdp/openthinrdp` | repository of the releases, `owner/repository` (for a fork) |
| `UPDATE_KEY` | `any` | signature an update from the management folder needs: `any` (project key or site key) or `site` (only the site key, once the device has it), see [management.md](management.md#a-fleet-on-its-own-key) |
| `UPDATE_TO` | `latest` | `latest` = the newest version published; a version (e.g. `0.2.0`) = exactly that one, also an older one (going back, FreeRDP included), and nothing newer until it changes. A pilot group: the current version in `common.conf`, `latest` for the pilot devices. Going back works to 0.2.0 or later. See [management.md](management.md#signed-updates) |
| `SSH` | `off` | `on` = SSH for the `otradmin` account, key login only |
| `REMOTE_SCREEN` | `on` | `off` = no remote screen from the manager ([management.md](management.md#remote-screen)); it needs `SSH=on` |

## Web button and kiosk page

| Key | Default | Meaning |
|---|---|---|
| `WEB_BUTTON` | `none` | `app` (only `WEB_URL` and `WEB_ALLOW`), `browser` (free browsing), `kiosk` (page full screen at power on) |
| `WEB_LABEL` | `Web` | button label |
| `WEB_URL` | | web address for `app` and `browser` |
| `WEB_ALLOW` | | other sites allowed in `app` mode (URL prefixes) |
| `KIOSK_URL` | | the kiosk page. The sign-in form shows for 5 s first: touching anything keeps it |
| `KIOSK_RELOAD_MIN` | `10` | reload the page every N minutes when idle (0 = never) |

## Power schedule

| Key | Default | Meaning |
|---|---|---|
| `POWER_ON_TIME` | | `hh:mm`, RTC wake alarm (firmware support needed, see [hardware.md](hardware.md)) |
| `POWER_OFF_TIME` | | `hh:mm`, with a 60 s warning that can be cancelled; waits for an open session to end |
| `POWER_ON_DAYS` | `1234567` | 1 = Monday ... 7 = Sunday |

## Look and language

| Key | Default | Meaning |
|---|---|---|
| `LANGUAGE` | `en` | `en`, `it`, `nl` (a file in `/opt/openthinrdp/lang/`) |
| `KEYBOARD` | `us` | X11 layout |
| `TITLE` | `Remote desktop` | window titles |
| `LOGO` | `/opt/openthinrdp/branding/logo.png` | logo in the dialogs. A logo in the management folder wins, see [management.md](management.md#logo-and-background-picture) |
| `BG_TOP`, `BG_BOTTOM` | `#1b2733`, `#000000` | background gradient (boot splash and behind the form) |
| `SUPPORT_TEXT` | | extra line in error messages, e.g. "Call the IT desk, ext. 123" |
| `SETTINGS_PIN_SHA256` | | protects the settings dialog. Set it from the manager, which stores `pbkdf2-sha256:<iterations>:<salt>:<key>` (salted PBKDF2-SHA256); by hand: `python3 -c 'import hashlib,os,sys; s=os.urandom(16); print("pbkdf2-sha256:600000:"+s.hex()+":"+hashlib.pbkdf2_hmac("sha256",sys.argv[1].encode(),s,600000).hex())' 123456`. The plain SHA-256 of 0.1.4 and earlier still works. Never shown in the status files |

`HOSTNAME`, `DEFAULT_USER`, `NETMODE` and `IPADDR` identify a device: in central settings they are accepted
only in `config\<hostname>.conf`, never in `config\common.conf`.
