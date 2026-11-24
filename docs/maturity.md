# Production readiness, area by area

A short, verifiable answer to "can I run this in production?", area by area: what is proven today, with the evidence,
and what comes next. It is updated when something changes. What runs where: [status.md](status.md).

## Security

**Covered**
- Vulnerability disclosure: [SECURITY.md](../SECURITY.md), private reporting on GitHub.
- FreeRDP security fixes reach a release within 7 days ([SECURITY.md](../SECURITY.md#freerdp-security-fixes));
  Debian security updates install by themselves on every device.
- Every update is signed and checked on the device before it is installed; the release key, how it is kept and how
  it is replaced or revoked: [SECURITY.md](../SECURITY.md#release-signing-key). A site can sign with **its own key**
  and accept only that one (`UPDATE_KEY=site`), so a compromised GitHub account cannot reach its devices.
- The keys of the manager live in an encrypted vault; device secrets (folder password, Wi-Fi key, SSH host keys) are
  kept in the TPM when there is one. The model and its known limits: [security.md](security.md).
- The packages of an image (name and version) are published with every ISO (`openthinrdp-<version>.packages.txt`);
  update packages change only OpenThinRDP and FreeRDP, Debian security updates come from Debian.

**Next**
- An independent security audit. Reviews and reports are welcome in the meantime.

## Automated testing

**Covered**
- System tests on every commit ([CI](https://github.com/OpenThinRdp/openthinrdp/actions/workflows/tests.yml),
  `tests/run-tests.sh`, about 240 checks): settings validation, central settings and their layers, updates with
  signature checks, pilot devices and **rollback**, interrupted and repeated installs, USB classification, secrets
  in a simulated TPM, language files.
- Manager tests (in its own repository, about 400 checks in Windows PowerShell 5.1, at every change): save plans, the configuration as text,
  permissions, the Health Center model, actions in dry-run mode.
- At every release the ISO boots in QEMU/KVM with Secure Boot; the UDP transport has a reproducible lossy-line bench
  ([tests/udp-bench](../tests/udp-bench/README.md)); 802.1X has a lab with hostapd and FreeRADIUS (`tests/lab-8021x`).

**Next**
- Network failures, reconnection, sign-in and USB are proven on real devices of the production fleet
  ([below](#tests-on-a-production-device)); running them automatically comes next.
- Proven on Windows 11 VDI behind Windows Server 2025 brokers; an automated run on other Windows Server versions comes
  next.

## Reliability in the field

**Covered**: one production fleet since October 2026, 15 Dell OptiPlex 3000 Thin Clients (desks, tills, a
laboratory, weighing stations, a wall screen on Wi-Fi). Since the first release (11 October - 24 November 2026):

| | |
|---|---|
| software updates installed | 399 |
| software updates failed | 0 |
| sessions opened | 537 |
| hours in session | 3,657 |
| sessions dropped by a lost network, reopened by themselves within 10 minutes (to 16 November) | 63 of 66 |
| starts of the kiosk | 767 |

**Outside our fleet**: 967 ISO downloads, more than 40 different models already running it (HP t520, t530, t620,
t655, IGEL M340C, Dell Wyse 5070, Centerm and Wyse thin clients, mini PCs, laptops, virtual machines), and 7 devices in
regular use outside our fleet. From 0.3.7 the devices also count, once, their first desktop: how many new devices get
to a working session, and how long it takes.

**Next**: these numbers grow here month by month, with every fleet that shares its own; the hardware test of the live
system sends a hardware report from any device, and a fleet report in the manager (uptime, updates, recovery times)
is planned.

## Tests on a production device

On one device of the production fleet (Dell OptiPlex 3000 Thin Client at a weighing station, outside working hours,
through its management folder and the manager, no hand-made shortcuts), 20-21 October 2026:

| test | result |
|---|---|
| **Rollback**: the device pinned to the previous version (`UPDATE_TO`) | back from 0.2.3 to 0.2.1 in **30 s** from the change in the folder, 4 s of install, the reason in its event log |
| **Interrupted update**: the install killed (`SIGKILL`) one second after it started | the device still knew it had the old version and **installed again by itself** after the 10 minute pause; 4 s, the kiosk restarted, nothing done by hand |
| **Network cut**: cable link down for 30 s | reachable again after 41 s, status in the folder again at the next 5 minute report, no restart |
| **Zero-touch**: management folder emptied, only the domain account left | the folder read from NETLOGON with the device's account, status sent there **1 s** later |
| **Sign-in through each broker**: two users, one through each RD Connection Broker | sessions open on their VMs in 17 s and 28 s |
| **Power**: switch off, Wake-on-LAN, restart from the manager | off in 7 s, up again by Wake-on-LAN in 21 s, back after a restart in 29 s |

What these tests found and fixed: on devices converted from another system the account is only in the credentials
file, and emptying the folder was refused (safely: the device kept its previous settings); fixed in 0.2.7. The
manager's *Name it in the domain* missed the account the devices report and wrote its first entry on the comment
line; fixed in 0.2.4.

## Release quality

**Covered**: every release has its notes in the [CHANGELOG](../CHANGELOG.md); a fleet can stay on a version
(`UPDATE_TO`), try a new one on pilot devices first, and go back to an earlier one, FreeRDP included, from the
manager; FreeRDP can be held on one device (`/etc/openthinrdp/freerdp-pinned`). Converting a fleet from Dell ThinOS
was done in place on the whole fleet ([guide](guides/replace-dell-thinos.md)).

**Next**: builds are documented and scripted ([building.md](building.md)); bit-for-bit reproducible builds come next.

## Independent adoption

**Covered**: issues from other administrators are answered and fixed in the open (for example
[#76](https://github.com/OpenThinRdp/openthinrdp/issues/76), [#80](https://github.com/OpenThinRdp/openthinrdp/issues/80),
[#83](https://github.com/OpenThinRdp/openthinrdp/issues/83), a Dutch translation contributed by a user testing it
on HP thin clients, a Chinese translation contributed by a user in China).

**Your fleet here**: running it? A short report in the
[test reports discussion](https://github.com/OpenThinRdp/openthinrdp/discussions/3) (hardware, Windows side, how many
devices) puts it on this page and helps everyone.

## Long-term maintainability

**Covered**: documentation for users and administrators ([configuration](configuration.md),
[management](management.md), [manager](manager.md), [security](security.md), [FAQ](faq.md)); build instructions
([building.md](building.md)); what to do when something goes wrong ([status.md](status.md#when-something-goes-wrong));
the whole client is shell scripts in `rootfs/opt/openthinrdp`, on Debian, with no proprietary part; GPLv3 keeps every
copy open.

**Next**: more maintainers. The project is maintained by the team that runs it in production every day, and
contributions are welcome.

## In short

Ready for a **gradual rollout** on Windows Remote Desktop (RDS, Hyper-V VDI): try it live, then on a few pilot
devices, then the rest, with rollback one click away. For Citrix, Horizon or a vendor support contract, see
[how it compares](alternatives.md).
