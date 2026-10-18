# Status: what you can deploy today

OpenThinRDP is numbered 0.x, but it is not a prototype: it runs a company's whole thin client fleet every day.
This page says what is used in production, what is available but not exercised by that fleet, and what does
not exist yet, so you know what to test before rolling it out.

## The production fleet

- **14 Dell OptiPlex 3000 Thin Clients** (BIOS 1.19 to 1.37) in offices, at the tills, in a laboratory and at
  weighing stations: 13 wired, one on **Wi-Fi** (a wall screen that shows a web page all day).
- **Windows 11 VDI on Hyper-V**: personal desktops behind two RD Connection Brokers (DNS round robin), plus a
  handful of session hosts.
- Every device was **converted in place** from the system it ran before, by an update package, with its settings
  carried over; none was reinstalled by hand.
- Updates reach them from the **management folder, signed with the key of the site**: the manager checks each GitHub
  release (project signature and hash) and signs it again with that key. Installed in the background during sessions
  and applied when the session is over. Until October 2026 the devices took the GitHub releases straight.

## In production every day

| Area | What |
|---|---|
| Sign-in | Kiosk sign-in screen, default user, two brokers with fallback, load balance info for VDI collections; **Kerberos with NTLM as fallback** behind the brokers' round-robin name; a session opened from another device is told apart from a VM shutdown |
| Transport | **RDP over UDP** (`TRANSPORT=auto`) with fallback to TCP; reconnection after network drops |
| Network | Wired (DHCP) and **Wi-Fi** (WPA2-PSK) |
| Web | **Web button** that opens the company portal (app mode, allowed sites only) on every device; a wall screen in **web kiosk** mode |
| USB | Whole-device redirection of signature keys and other special devices, also plugged in during the session |
| Meetings | Webcams through the RDP camera channel, microphones and speakers through the RDP audio channels |
| Smart cards | Readers through the smart card channel (pcscd) |
| Touch | Touch screens at the tills, as real touch in Windows |
| Management | Status and events of every device, central settings (common and per device), logo and background, Windows manager |
| Updates | Signed packages from the **management folder** with the **site key** (`UPDATE_FROM=share`, `UPDATE_KEY=site`), the GitHub releases checked and signed again by the manager; straight from GitHub (`UPDATE_FROM=github`) before. Debian security updates by themselves |
| Power | Shutdown at the end of the session, Wake-on-LAN (also from the BIOS), **power on and off on a schedule** (the wall screen: RTC wake alarm) |

## Available, not exercised by that fleet

These work in our tests (QEMU/KVM at every release, the system tests in `tests/`, a test device), but the
production fleet does not use them, so test them in your environment first:

- **ISO installation** on new hardware: live system and automatic installation, Secure Boot. Tested in QEMU/KVM
  with Secure Boot at every release; the fleet itself was converted in place, not installed from the ISO.
- Static addressing (the fleet uses DHCP).
- Web button in free browsing mode (`WEB_BUTTON=browser`).
- `RDP_CERT=verify` with your own certificate authority.
- Devices outside the office: the RD Gateway (`RDP_GATEWAY`), tested against a Windows Server RD Gateway, and the
  VPN (`VPN=wireguard|openvpn`), tested against WireGuard and OpenVPN servers (tunnel, routes, DNS, a refused
  password). No device of the fleet works outside the office yet.
- **A pilot group and going back** (`UPDATE_TO`): a version on a few devices first, the others kept where they are,
  and back to an earlier version with its FreeRDP. In the system tests (management folder and GitHub, going back with
  the packages of that version), new in 0.2.0.
- **The manager updating itself** from the signed releases, new in 0.2.0.
- **802.1X and WPA2/WPA3-Enterprise Wi-Fi** (PEAP, EAP-TLS): in the system tests and in a lab against hostapd and
  FreeRADIUS, new in 0.2.1; not yet on a real switch or with Windows NPS.
- **Desktops in the cloud** (Azure, AWS, any provider): the same RDP, through an RD Gateway or a VPN, but we have
  no cloud deployment to test on ([what to know](configuration.md#desktops-in-the-cloud)).
- **Raspberry Pi 4** (arm64), experimental: an SD card image
  ([pre-release](https://github.com/OpenThinRdp/openthinrdp/releases/tag/rpi-test-1)), tested only in QEMU arm64
  emulation, not yet on a real board ([what to check](arm.md)).

## Not available yet

- Citrix, VMware/Omnissa Horizon or any protocol other than RDP.
- Azure Virtual Desktop and Windows 365 (Microsoft Entra ID sign-in and Microsoft's gateway).
- The Raspberry Pi 5 and other ARM devices.
- Network boot (PXE).
- Disk encryption, signed central configuration.

Tell us what you need first in the [discussions](https://github.com/OpenThinRdp/openthinrdp/discussions).

## Tested hardware

| Device | Status |
|---|---|
| Dell OptiPlex 3000 Thin Client | production (14 devices, one of them on its built-in Wi-Fi) |
| QEMU/KVM, UEFI with Secure Boot | tested at every release |

Other x86-64 PCs and thin clients with UEFI should work: reports in the
[discussions](https://github.com/OpenThinRdp/openthinrdp/discussions) are very welcome.

## When something goes wrong

- **A device cannot reach the management folder.** It keeps the last settings it read (the last good
  configuration) and keeps working. The ℹ button of the sign-in screen shows the network and the reachability
  of the folder and of the brokers; the settings dialog (PIN) fixes the folder, user or password on the device.
- **An update is interrupted.** A package is checked (signature, hash, syntax of every script) before anything
  is touched; Shut down waits for a running install. If the power goes in the middle, the device installs the
  same package again at its next check, because its version is still the old one.
- **Going back.** Devices never install an older version. To go back, publish the older package again under a
  higher version number, or reinstall the device from the ISO: its settings come back from the management folder.
- **A device is stolen.** Rotate the management folder password (`MGMT_PASSWORD` in the central settings) and,
  if it had one, the password of the session user. See [security.md](security.md).
