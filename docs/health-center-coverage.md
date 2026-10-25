# Health Center coverage

The Health Center of the manager (page **Health Center**; what it runs on the servers is in `commands\` of the manager) was built from the
emergency runbook script of the first site that ran OpenThinRDP with Hyper-V VDI: an interactive PowerShell menu with
an automatic check-and-repair run, about fifty numbered runbook commands and a few maintenance procedures. This page
lists every check and every command of that script, one row each, and says:

- **generic**: it makes sense on any Hyper-V / Remote Desktop / Active Directory site, so the Health Center has it;
- **site**: it belongs to that site only (a line-of-business application, a lab instrument, fixed lists of names):
  not ported. Most of these can be written by each site as a [custom check](manager.md#custom-checks).

Unlike the script, which had the names of its servers written in it, the Health Center finds no server by itself:
every server is entered by its role in Settings > Health Center (see [manager.md](manager.md#settings-and-what-it-needs)).

Where = the item of the tree that shows it (with the name of its row) or the action that does it. Every item shows
**every** check it ran, with its result: OK rows included (`HcC_*` texts), not only the problems.

## Automatic run (check, then repair the safe things)

| # | Check of the script | Kind | Where in the Health Center |
|---|---|---|---|
| A1 | Domain controllers reachable, ports 88/389/445/53, ADWS 9389 | generic | domain > DC: *Domain controller ports* |
| A2 | AD queries answer (LDAP, Get-ADDomain) | generic | DC: *Directory queries* |
| A3 | DC services (NTDS, DNS, KDC, Netlogon, ADWS, DFSR, W32Time), start the stopped ones | generic | DC: *Domain controller services*, fix *Start* (safe) |
| A4 | SYSVOL / NETLOGON shared | generic | DC: *SYSVOL and NETLOGON* |
| A5 | Replication (repadmin summary, last failures) | generic | DC: *Replication*, action *Sync all* |
| A6 | DNS of the DC: itself not first, loopback | generic | DC: *DNS servers of the DC* |
| A7 | Settings alike on the DCs | generic | DC: *Same settings on the DCs* |
| A8 | Clock: offset from the PDC, PDC with an external source | generic | every server: *Clock*, action *Resync clock* (safe) |
| A9 | Secure channel with the domain | generic | every server: *Trust with the domain*, fix *Restart Netlogon* |
| A10 | Brokers: services (Tssdis, TermService, RDMS) | generic | broker: *Services*, fix *Start* / *Unblock* |
| A11 | Brokers: 802/804 errors, fails every sign-in, balance of the connections | generic | broker (Desktops findings), headline *who cannot sign in now* |
| A12 | Broker database: listener, heartbeat, third/phantom broker, DB node | generic | broker: *Broker database*, *Broker heartbeat*, RDS DB item |
| A13 | Broker certificate (RDP): missing, wrong name, expired, expiring | generic | broker: *Remote Desktop certificate* |
| A14 | Brokers reach the hosts (event 1295) | generic | broker: *Broker reaches the hosts* |
| A15 | Stuck services (StopPending/StartPending) on hosts, brokers, servers | generic | every server: *Services*, fix *Unblock* (safe for VmHostAgent, vmms, W32Time) |
| A16 | RDVH agent (VmHostAgent): running, Tssdis list, map of the brokers | generic | host: *RDVH agent and brokers*, fix *Copy Tssdis*, *Unblock* |
| A17 | Host permissions of the brokers (the three local groups) | generic | host (Desktops finding), fix *Host permissions* (safe) |
| A18 | VMs saved / saved with vTPM / paused / not answering | generic | VM: *VM state*, actions *Start*, *Resume*, *Remove saved state* |
| A19 | Cluster OfflineAction 1 (VMs saved when a node stops) | generic | cluster: *VMs shut down, never saved*, fix *OfflineAction 2* (safe) |
| A20 | VM roles offline / failed in the cluster | generic | VM: *Cluster role of the VM*, fix *Start role* |
| A21 | SQL AlwaysOn: replicas, sync state, suspended databases | generic | SQL > replica: *Replica*, *Databases synchronized*, fix *Resume* |
| A22 | SQL services and SQL Agent | generic | replica: *SQL services*, fix *Start* (safe) |
| A23 | Logins and jobs alike on the replicas | generic | replica: *Logins as on the other replica*, *SQL Agent jobs* |
| A24 | Witness of the cluster online | generic | cluster: *Witness*, fix *Witness online* (safe); device: *Witness of the cluster* |
| A25 | NAS awake (ping, SMB), Wake-on-LAN | generic | devices: *Answers on the network*, *Ports*, *Shared folder*, action *Wake* |
| A26 | Intranet portal answers its health page | site | custom check (example 2 in the manager guide) |
| A27 | Line-of-business application servers (two ports, the terminal service) | site | custom check |

## Quick look, complete DC check, cluster host check, backup, orchestration chain, DNS

| # | Check | Kind | Where |
|---|---|---|---|
| Q1 | Free memory of every server | generic | every server: *Memory* (thresholds in Settings > Health Center) |
| Q2 | Free disk space | generic | every server: *Disk space* |
| Q3 | Pending restart | generic | every server: *Pending restart* |
| Q4 | Critical events in the last 24 h | generic | every server: *Critical events* |
| Q5 | APIPA address on an active adapter | generic | every server: *Network addresses* |
| Q6 | Server Manager list with dead names | generic | every server: *Server Manager list*, fix *Clean* (safe) |
| Q7 | Uptime | generic | every server: fact *Up since* |
| H1 | Hyper-V and cluster services (vmms, VmHostAgent, ClusSvc) | generic | host: *Hyper-V and cluster services* |
| H2 | Cluster node state (Up/Paused/Down), cluster quorum | generic | host: *Cluster node*; cluster: *Nodes*, fix *Force quorum* (asks) |
| H3 | S2D pool, virtual disks, physical disks, repair jobs | generic | cluster: *Storage pool and virtual disks*, *Storage repair jobs* |
| H4 | CSV online, free space, reachable from every node | generic | cluster: *Cluster shared volumes*; host: *Cluster volumes reachable* |
| H5 | Cluster networks and live migration network | generic | cluster: *Cluster networks* |
| H6 | Network adapters up, driver and firmware alike on the nodes | generic | host: *Network adapters* (fact per adapter, driver date) |
| H7 | vTPM guardian keys on every node | generic | host: *vTPM guardian* |
| H8 | Room for the VMs of a node on the others | generic | cluster: *Room for the VMs of a node* |
| H9 | Drain on shutdown | generic | cluster: *Drain on shutdown*, fix (asks) |
| H10 | Anti-affinity of the pairs (two DCs, two brokers, two replicas) | generic | cluster: *Two VMs of the same role on one node*, fix *Move live* |
| H11 | Power: UPS / battery | generic | host: *Power (UPS)* (when Windows sees a battery) |
| H12 | Fixed list of the anti-affinity pairs of the site | site | found by role instead (H10) |
| H13 | The 25G storage link with its fixed addresses | site | generic part in H5 / H6 |
| B1 | VM backup log of the NAS (last run, errors, hours) | generic | backups: *Backup log* (path, text, hours in Settings) |
| B2 | SQL backups per database, log backups | generic | SQL: *Database backups* |
| B3 | SQL Writer (VSS) on the replicas | generic | replica: *SQL Writer (VSS)* |
| B4 | VMs without a backup, crash-consistent only | generic | VM: *VM backup* |
| B5 | The backup agent of the NAS vendor (its own events) | site | generic part in B1 |
| O1 | Orchestration chain: broker -> RDVH agent -> host -> VM (Tssdis, permissions, agent events) | generic | host: *RDVH agent and brokers*; broker: *Broker reaches the hosts* |
| O2 | Chain repair (unblock the agent, restart the broker services in order) | generic | action *Unblock the sign-in chain* (asks) |
| D1 | DNS servers answer, answer time | generic | DNS: *DNS servers* |
| D2 | Names with two addresses, missing names | generic | DNS: *Names and addresses*, fix *Unregister* |
| D3 | Reverse zones and slow reverse lookups | generic | DNS: *Reverse lookup*, fix *Create reverse zone* |
| D4 | Scavenging of old records, stale records | generic | DNS: *Scavenging of old records* |
| D5 | Zones on every DC, FSMO roles | generic | domain: *DNS zones on every DC*, *Operation masters* |

## Runbook commands

| # | Command | Kind | Where |
|---|---|---|---|
| 1 | List all VMs with state and node | generic | tree cluster > host > VM, and the Distribution view |
| 2 | Complete DC check | generic | DC items (A1-A7) |
| 3 | Replication summary | generic | DC: *Replication* |
| 4 | Resolve the broker name | generic | broker: facts, DNS: *Names and addresses* |
| 5 | Broker services | generic | broker: *Services* |
| 6 | Recent broker errors 802/804 | generic | broker (Desktops findings) |
| 7 | AlwaysOn state of the broker database | generic | SQL: *Listener*, replicas |
| 8 | User VMs with heartbeat and node | generic | VM items, Distribution view |
| 9 | Clock of DCs, brokers, other servers | generic | every server: *Clock* |
| 10 | Secure channel of the brokers | generic | *Trust with the domain* |
| 11 | Cluster host check | generic | host and cluster items (H1-H11) |
| 12 | Hyper-V event log of the nodes | generic | host: *Critical events*, *RDVH agent and brokers* |
| 13 | Intranet portal port | site | custom check |
| 14 | Sessions in the broker database | generic | Distribution view (session column), VM: fact *Windows session* |
| 15 | Backup check | generic | B1-B4 |
| 16 | SQL services on both nodes | generic | replica: *SQL services* |
| 17 | Logins compared between the replicas | generic | replica: *Logins as on the other replica* |
| 18 | Preferred primary of the AG | generic | replica: fact *Role*; action *SQL failover* (asks) |
| 19 | Orchestration chain | generic | O1 |
| 20 | Start a VM on the right node | generic | VM: action *Start* |
| 21 | Unblock a user VM (stuck saved state) | generic | VM: *Remove saved state*, *Restart* |
| 22 | Restart the broker services | generic | broker: fix *Restart broker* (safe while another broker serves) |
| 23 | Resync the clock of a server | generic | action *Resync clock* (safe) |
| 24 | Restart Netlogon of a broker | generic | fix *Restart Netlogon* |
| 25 | Restart the services of a DC | generic | DC: action *Restart DC services* (asks; refused without another healthy DC) |
| 26 | Portal health page | site | custom check |
| 27 | Restart the RDVH agent only while a broker is healthy | generic | fix *Unblock* of VmHostAgent (the same guard) |
| 28 | Force replication of a DC | generic | DC: action *Sync all* |
| 29 | Repair Tssdis of a host | generic | host: fix *Copy Tssdis* |
| 30 | Drain a node | generic | host: action *Drain* (guards: other nodes up, witness online, no storage repair, room) |
| 31 | Put a node back in service with failback | generic | host: action *Resume* (failback immediate) |
| 32 | Quick unblock of the sign-in chain | generic | action *Unblock the sign-in chain* |
| 33 | Move everything to one node | generic | host: action *Move all VMs to the other node* (node stays in service) |
| 40 | A node is dead: procedure | generic | cluster: *Nodes*, action *Force quorum* (asks, only without quorum) |
| 41 | AG failover to a chosen node | generic | SQL: action *SQL failover* (asks; refused while not synchronized) |
| 42 | Seize FSMO roles (shown only) | generic | advice only: the Health Center shows the roles, never seizes |
| 43 | Authoritative SYSVOL restore (shown only) | generic | advice only: *SYSVOL and NETLOGON* explains |
| 44 | Readable secondary errors (976) | generic | replica: *Readable secondary* |
| 45 | COPY_ONLY backup of the broker database | generic | SQL: action *Copy-only backup* (asks) |
| 46 | Complete DNS check | generic | D1-D5 |
| 47 | Wake the NAS (Wake-on-LAN) | generic | device: action *Wake* (safe) |
| 48 | Line-of-business application servers | site | custom check |
| 49 | Their repair | site | repair script of a custom check |
| 50 | Orchestration chain with repair | generic | O1 + O2 in repair mode |

## Home menu

| # | Entry | Kind | Where |
|---|---|---|---|
| M1 | Automatic run (check and repair) | generic | mode *Repair* (page or item): safe repairs run by themselves, one server per role |
| M2 | Runbook commands | generic | actions of the items (above) |
| M3 | Diagnosis only | generic | mode *Diagnosis only* |
| M4 | Shut down or restart a server safely | generic | actions *Restart the server* / *Shut down the server*, with the guards (node drained first, another DC / broker, secondary replica only) |
| M5 | Back in service after a restart | generic | host: *Resume* (failback) |
| M6 | Full backup on a removable disk (disaster recovery) | site | not ported: depends on the disks and the export folders of the site; documented as a manual procedure |
| M7 | Password of the local administrator (LAPS) | generic | action *Local administrator password (LAPS)*, read only, logged in changes.log |
| M8 | SQL Writer on/off on both nodes | generic | replica: *SQL Writer (VSS)* shows it; switching it stays manual |

## Totals

- Rows: 111 (automatic run 27, quick look and procedures 32, runbook commands 44, home menu 8).
- Site rows: 10 (A26, A27, H12, H13, B5, 13, 26, 48, 49, M6). Commands 42 and 43 are advice only, as in the script.
- Generic rows: 101, every one covered by a check row or an action of the Health Center.
