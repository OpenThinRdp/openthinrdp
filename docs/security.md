# Security model

A thin client is a public-facing device: anyone can sit at it. OpenThinRDP assumes that whoever is at the
keyboard is untrusted and that the management folder is readable by the devices only.

## What protects what

- **No shell for the user.** Openbox without menus or key bindings; the only programs are the sign-in form,
  FreeRDP and, if enabled, Chromium with policies (no downloads, extensions, developer tools, guest or
  incognito windows; in `app` mode only the allowed sites).
- **No text consoles.** Ctrl+Alt+F1..F12 do not leave X (`DontVTSwitch`), there are no spare consoles with a
  login prompt (`NAutoVTs=0`), and the `kiosk` account is locked: it logs in automatically on tty1 only.
  (0.1.0 left `kiosk` with an empty password and the spare consoles on: anybody at the keyboard could get a
  shell with Ctrl+Alt+F2. Fixed in 0.1.1, also on devices updated from 0.1.0.)
- **Diagnostics without a PIN** (the ℹ button of the sign-in form): read only, it shows the network, the
  reachability of the remote desktop hosts and the last events, never a setting or a secret.
- **Settings dialog behind a PIN** (`SETTINGS_PIN_SHA256`). Without a PIN anyone at the device can point it to
  another broker. The "Terminal" button of the dialog opens a shell as the `kiosk` user.
- **`kiosk` has one root privilege:** `save-config.sh`, which validates every value before touching the system.
- **No password in the image.** `root` is locked; `otradmin` has no password unless you set a hash in
  `build.conf`; SSH is off by default and accepts only keys.
- **Signed updates.** A package is installed only with a valid signature (verified with `sqv`): the
  project key, or with `UPDATE_FROM=share` also your own key ([management.md](management.md#signed-updates)),
  and a matching hash; never an older version.
- **Credentials.** The user's password goes to FreeRDP on its command line, which FreeRDP overwrites with `*`
  right after start (visible to the local `kiosk` account for a moment at most); it is never stored. The Wi-Fi
  key and the management folder password are never reported or printed back (`save-config.sh --print` shows
  only their hash). The settings PIN hash is never written to the status files.
- **The device's secrets in the TPM, when there is one.** The management folder password, the Wi-Fi key, the
  SSH host keys, the VPN key and profile, and the 802.1X password and the private key of the 802.1X certificate
  ([configuration.md](configuration.md#8021x-and-wi-fi-enterprise)) are the only secrets on the device. With a TPM 2.0 (most PCs and thin clients since about 2016)
  they are kept in `/etc/openthinrdp/sealed/`, encrypted with a key that never leaves the TPM
  (`systemd-creds --with-key=tpm2`), and decrypted at every start into `/run/openthinrdp/secrets/`, in memory
  only, before the network and SSH start. A disk or eMMC taken out of the device, or an image of it, gives
  nothing. They are bound to the TPM only, not to firmware measurements (PCRs), so a BIOS update or a Secure Boot
  change does not lose them. Devices set up before move their plain files into the TPM at the next start; the
  status file says which mode a device is in (`SECRETS=tpm` or `SECRETS=file (no TPM)`, also in the manager).
  Without a TPM they stay in root-only files (600), as before, so older PCs keep working. The folder password, the
  Wi-Fi key and the 802.1X certificate key keep their usual paths, links to the copy in memory, so the network configuration never changes; a
  secret is read back from the TPM and compared before its plain file is deleted. `TPM_SECRETS=off` (central or per
  device) keeps a device out of the TPM, and puts back in root-only files the secrets of a device that had them there,
  at the next start; set centrally, it counts from the first start after the update. To roll it out, set it off in
  `common.conf`, on for one device, restart that one twice, then remove the line.
  If the TPM is cleared or replaced, or the disk moved to another device, the secrets cannot be read: an event
  says so, the SSH host keys are created again, and the folder password and the Wi-Fi key must be set again.

- **Remote screen only through SSH.** x11vnc and the viewer's WebSocket bridge listen on 127.0.0.1 only, run as the
  account that owns the screen (not root), start only when an administrator asks over SSH (`otradmin`, key login)
  and need a one-time password. While the remote screen is on, the device says so on its screen and its event log
  records start and end; it stops by itself after 2 hours. `REMOTE_SCREEN=off` turns it off
  ([management.md](management.md#remote-screen)).

## Known limits

- `smb.cred` is on every device: a stolen device gives its holder that account. Give it write access to
  `status\` only and read access to the rest of the management folder ([management.md](management.md#account)):
  then that account cannot change the settings of the other devices nor offer them anything to install. Change
  the password if a device is lost (`MGMT_PASSWORD` in the central settings rotates it on every device that can
  still reach the folder).
- The management folder is trusted: whoever can write `config\` can change the settings of every device
  (within the validation rules) and can make devices mount another folder. Updates still need a valid
  signature (the project key, or your own key).
- `RDP_CERT=ignore` accepts any server certificate. The default `tofu` trusts the first certificate seen per
  server; `verify` requires certificates trusted by the system.
- The PIN is a speed bump, not a vault. The manager stores it salted and stretched (PBKDF2-SHA256, 600,000
  iterations, about 0.2 s per try on a thin client): a 6-digit PIN takes days to brute-force from a stolen
  settings file, a 4-digit one less than an hour, so use 6 digits or more. A PIN set by 0.1.4 or earlier is a
  plain SHA-256 and still works; set it again from the manager to store it the new way.
- The disk is not encrypted as a whole: the code is public and no user data is stored on the device, so only the
  secrets above are protected, and only with a TPM. Without one, physical access to the disk gives them. With one,
  the whole device in someone's hands still starts and uses them, like any device that boots unattended; lock the
  firmware setup and USB boot with a BIOS password, and rotate the folder password if a device is lost. Plain
  copies deleted when the secrets moved into the TPM may survive in flash memory blocks until overwritten.

Report security problems privately to the maintainers (GitHub security advisories) rather than in a public issue.
