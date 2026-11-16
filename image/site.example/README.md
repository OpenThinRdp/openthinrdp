# Site folder

Everything that makes the image yours. Copy this folder to `image/site` (ignored by git) and edit it.

| File | Goes to | Purpose |
|---|---|---|
| `build.conf` | (build only) | language, time zone, keyboard, `otradmin` password, FreeRDP source |
| `site.conf` | `/etc/openthinrdp/site.conf` | default settings for every device (broker, domain, management folder...) |
| `logo.png` | `/opt/openthinrdp/branding/logo.png` | logo in the dialogs, about 200 px wide |
| `splash.png` | boot splash and background | logo on the boot screen, about 640 px wide, transparent background; used as it is whatever the colours (without one, the project's logo: transparent on dark colours, on its dark card on light ones) |
| `ca/*.crt` | `/etc/openthinrdp/ca/` | certificate authorities trusted by the web button (PEM) |
| `smb.cred` | `/etc/openthinrdp/smb.cred` | account for the management folder (`username=`, `password=`, `domain=`) |
| `update-key.asc` | `/etc/openthinrdp/update-key.asc` | public key that signs your updates (management/publish) |
| `authorized_keys` | `/etc/openthinrdp/authorized_keys` | SSH keys of the administrators (with `SSH=on`) |
| `debs/*.deb` | installed in the image | your own packages, e.g. a FreeRDP build |

Missing files are simply left out: the project defaults are used.

`smb.cred` ends up in every image: use an account that can only write the management folder.
