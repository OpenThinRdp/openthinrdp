# Production readiness: what is covered, what is not yet

A short, verifiable answer to "can I run this in production?", area by area: what exists today with the evidence,
and what is still missing. It is updated when something changes. What runs where: [status.md](status.md).

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

**Not yet**
- No independent security audit. We cannot provide one ourselves; reviews and reports are welcome.
- No SBOM per release yet: the packages of an image are those of Debian 13 at build time plus FreeRDP, but the list
  is not published with each release.

## Automated testing

**Covered**
- System tests on every commit ([CI](https://github.com/OpenThinRdp/openthinrdp/actions/workflows/tests.yml),
  `tests/run-tests.sh`, about 240 checks): settings validation, central settings and their layers, updates with
  signature checks, pilot devices and **rollback**, interrupted and repeated installs, USB classification, secrets
  in a simulated TPM, language files.
- Manager tests (`tests/windows`, about 240 checks in Windows PowerShell 5.1): save plans, the configuration as text,
  permissions, the Health Center model, actions in dry-run mode.
- At every release the ISO boots in QEMU/KVM with Secure Boot; the UDP transport has a reproducible lossy-line bench
  ([tests/udp-bench](../tests/udp-bench/README.md)); 802.1X has a lab with hostapd and FreeRADIUS (`tests/lab-8021x`).

**Not yet**
- Network failures, reconnection, sign-in and USB are tested on real devices by hand, not automatically.
- No automated matrix of Windows Server versions: the fleet runs Windows 11 VDI behind Windows Server 2025 brokers.

## Reliability in the field

**Covered**: one production fleet since October 2026, 15 Dell OptiPlex 3000 Thin Clients (desks, tills, a
laboratory, weighing stations, a wall screen on Wi-Fi). From the event logs the devices keep (11-20 October 2026):

| | |
|---|---|
| software updates installed | 189 |
| software updates failed | 0 |
| sessions opened | 175 |
| automatic reconnections | 57 |
| starts of the kiosk | 261 |

**Not yet**: months of data, and fleets other than ours. The numbers will be updated here as they grow; a fleet
report in the manager (uptime, failed updates, recovery times) is planned.

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

**Not yet**: builds are documented and scripted ([building.md](building.md)) but not bit-for-bit reproducible.

## Independent adoption

**Covered**: issues from other administrators are answered and fixed in the open (for example
[#76](https://github.com/OpenThinRdp/openthinrdp/issues/76), [#80](https://github.com/OpenThinRdp/openthinrdp/issues/80),
[#83](https://github.com/OpenThinRdp/openthinrdp/issues/83), a Dutch translation contributed by a user testing it
on HP thin clients).

**Not yet**: documented deployments by others. If you run it, a short report in the
[test reports discussion](https://github.com/OpenThinRdp/openthinrdp/discussions/3) (hardware, Windows side, how many
devices) helps everyone.

## Long-term maintainability

**Covered**: documentation for users and administrators ([configuration](configuration.md),
[management](management.md), [manager](manager.md), [security](security.md), [FAQ](faq.md)); build instructions
([building.md](building.md)); what to do when something goes wrong ([status.md](status.md#when-something-goes-wrong));
the whole client is shell scripts in `rootfs/opt/openthinrdp`, on Debian, with no proprietary part; GPLv3 keeps every
copy open.

**Not yet**: the project is maintained by the team that runs it in production; more maintainers would lower the risk
of depending on one team.

## In short

Ready for a **gradual rollout** on Windows Remote Desktop (RDS, Hyper-V VDI): try it live, then on a few pilot
devices, then the rest, with rollback one click away. It is not the right choice yet if you need vendor support,
certified hardware, an audit report or protocols other than RDP.
