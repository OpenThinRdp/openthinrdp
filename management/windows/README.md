# The OpenThinRDP Manager has moved

Up to OpenThinRDP 0.2.22 this folder held the manager for Windows as PowerShell scripts that read the management
folder and wrote the `.conf` files of the devices. That is history: since 0.2.23 the manager is a project of its own,
and since **1.0.0** (28 October 2026) it has releases of its own, signed with the project key, and updates itself.

**[OpenThinRDP Manager](https://openthinrdp.github.io/manager.html)** is a free Windows application (Windows 10/11 and
Windows Server, English and Italian, nothing to install) with two parts in one window:

- a **health center for the Windows infrastructure**, also without any OpenThinRDP device: Hyper-V hosts and failover
  clusters, Remote Desktop Services, domain controllers and DNS, SQL Server AlwaysOn, VM backups, Dell iDRAC and other
  Redfish controllers, Proxmox, vSphere, Veeam, Citrix and certificates. What is wrong, in one sentence, and the repair
  after you confirm. No agent, no server, no database;
- **the management of an OpenThinRDP fleet**: every device, its state and sessions, settings for all devices or one,
  pilot devices and going back, the screen of any device in the browser.

- Download: [latest release of the manager](https://github.com/OpenThinRdp/openthinrdp-manager/releases/latest)
- Its page: [openthinrdp.github.io/manager.html](https://openthinrdp.github.io/manager.html)
- Every page of it: [docs/manager.md](../../docs/manager.md)
- A free health check for Hyper-V and Remote Desktop: [the guide](../../docs/guides/hyper-v-rds-health-check.md)
- Questions and reports: [issues of the manager](https://github.com/OpenThinRdp/openthinrdp-manager/issues)

The manager of the releases up to and including 0.2.22 was published under the GNU GPL version 3 or later and stays
under it; the manager from 0.2.23 is free for any use but closed ([its license](https://github.com/OpenThinRdp/openthinrdp-manager/blob/main/LICENSE.md)).
