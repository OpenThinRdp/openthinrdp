# A free health check for Hyper-V clusters and Remote Desktop, without an agent

Small and mid-size sites run Hyper-V, a failover cluster, Remote Desktop Services and SQL Server on a few hosts, and
find out what broke when users call: the witness went offline last week, a CSV is almost full, one broker refuses
every sign-in, a VM is still in saved state after a power cut, the backups of a VM have been crash-consistent for days.
The monitoring suites that see all of this cost per host and need agents and a server of their own.

The [OpenThinRDP Manager](https://github.com/OpenThinRdp/openthinrdp-manager) is a free Windows program that reads all
of it from your PC, with the account you already use for administration, and shows it in one window. It was built
for the sites that run [OpenThinRDP](../../README.md) thin clients, and it works the same without them.

<p align="center">
<img src="../screenshots/manager-health.png" alt="Health Center: Hyper-V hosts and cluster, VMs, domain controllers, SQL and backups in one tree, each problem in one sentence" width="100%">
</p>

## What it checks

- **Hyper-V hosts**: memory, CPU, disks, services, restarts pending, the clock, VMs off, saved, paused or without
  heartbeat, checkpoints left for days, planned VMs left behind by a failed migration, the guardians of the vTPM.
- **The failover cluster**: nodes, quorum and witness (and *why* a file share witness is offline: the server, the
  share or the permissions), the Cluster Shared Volumes and their free space, the Storage Spaces Direct pool, its disks
  and repairs, the networks for live migration, whether the cluster survives one host failing with the VMs it runs.
- **Remote Desktop Services**: the connection brokers and their database, the RDP certificates, the session hosts and
  the virtual desktops, **who cannot sign in right now and why**, RD Gateway and RD Web, and a self-repair for a broker
  that starts refusing every sign-in (event 804, `0x80070005`).
- **Active Directory and DNS**: domain controllers, replication, FSMO roles, SYSVOL and NETLOGON, the clock against
  the PDC emulator, ADWS, the DNS zones, missing reverse zones, stale records.
- **SQL Server AlwaysOn**: the listener, replicas and synchronisation, suspended databases, logins missing on a
  replica, failed jobs, backups.
- **Backups**: the backups of the VMs as Hyper-V sees them (application-consistent or not), and a backup of the VMs to
  a share made by the hosts themselves, without an agent and without moving a VM.
- **Hardware**: Dell iDRAC over Redfish (power now and over 24 hours, power supplies, temperatures, fans).
- **Your services as their users reach them**: a web page, a TCP port, a SQL query; and your own checks.
- **Certificates**: every certificate of every server, what uses it and when it expires, the enterprise CA and its
  revocation list, and which RDP servers present a certificate a client could verify.
- **Not only Hyper-V** (new, looking for sites to try them): Proxmox VE, VMware vSphere, Veeam Backup & Replication and
  Citrix Virtual Apps and Desktops, each from its own API, read only.

Every problem is one sentence with its numbers, what it means, and a repair when there is one: you see what it will do
and confirm. Over time: history and forecast for memory, disks and volumes, notices when a problem comes or goes,
maintenance per item, and `-HealthReport -Json` for Task Scheduler or your monitoring system.

## What it needs

- A Windows PC or server with Windows PowerShell 5.1 (every Windows 10/11 and Windows Server 2016 or later).
- An account that administers the servers, with WinRM (5985) to the hosts, domain controllers, brokers and SQL
  replicas, and Windows authentication on SQL. Without administrator rights, a JEA endpoint can give it only the
  commands it needs.
- Nothing on the servers: no agent, no service, no database. What it runs there is plain PowerShell you can read, in
  `commands\` and `rds\` of the manager.

## In five minutes

1. Download the zip of the [latest release](https://github.com/OpenThinRdp/openthinrdp-manager/releases/latest) and
   extract it, on a share if more administrators use it.
2. Start `OpenThinRDP-Manager.exe` and choose **The servers alone**.
3. **Settings > Health Center**: the Hyper-V hosts (or one node of the cluster), the brokers, the SQL listener, the
   backup share. The first reading takes about half a minute; then **Home** shows everything at a glance.

## What it is not

- Not a replacement for a full monitoring suite with alerting on hundreds of servers: it is built for a site with a
  few hosts and the people who run them.
- The manager runs on Windows; the hardware is read over Redfish (Dell, HPE, Lenovo, Supermicro).
- Free for any use, also commercial, but not open source: [its license](https://github.com/OpenThinRdp/openthinrdp-manager/blob/main/LICENSE.md).
  Everything it runs on your servers is readable.

The full guide of the manager: [manager](../manager.md).
