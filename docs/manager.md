# The OpenThinRDP manager

The manager is the one place where you run a fleet of OpenThinRDP devices: one PowerShell script for Windows 10/11,
in English and Italian, with nothing to install. It works on the shared folder the devices report to: no server,
no agent, no database. What you see is the files in that folder, and everything you change is a file in that
folder too, with a backup and a line in the change log.

<p align="center">
<img src="screenshots/manager-devices.png" alt="Devices page: every device with its state, user, version and last report; the selected device with its settings" width="100%">
</p>

- [What you need](#what-you-need)
- [Devices: the whole fleet at a glance](#devices-the-whole-fleet-at-a-glance)
- [Settings for all devices or one](#settings-for-all-devices-or-one)
- [Updates: a few devices first, then all, and back when something breaks](#updates-a-few-devices-first-then-all-and-back-when-something-breaks)
- [Remote screen](#remote-screen)
- [Problems across the fleet](#problems-across-the-fleet)
- [Desktops, brokers and Hyper-V hosts](#desktops-brokers-and-hyper-v-hosts)
- [Vault, keys and the site key](#vault-keys-and-the-site-key)
- [Logo, background, SSH keys, permissions](#logo-background-ssh-keys-permissions)
- [The manager updates itself](#the-manager-updates-itself)
- [Starting it, and the command line](#starting-it-and-the-command-line)

## What you need

- A **shared folder** (SMB) that the devices can read and write their status to: `\\fileserver\thinclients`. How
  to create it, its account and its permissions: [management.md](management.md#account).
- A **Windows 10 or 11 PC** of an administrator, with PowerShell 5.1 (it is part of Windows). For the remote screen,
  also the OpenSSH client of Windows (`ssh.exe`, usually there) and a browser.
- **The manager itself**: `openthinrdp-manager-<version>.zip` from the [latest release](https://github.com/OpenThinRdp/openthinrdp/releases/latest),
  unpacked into a folder only the administrators can write (a share works, so that everybody starts the same copy).
  From then on it [updates itself](#the-manager-updates-itself).
- The devices set to that folder: `MGMT_SHARE` in their settings dialog, or in the image you build.

Start `OpenThinRDP-Manager.vbs` (no console window) or `OpenThinRDP-Manager.cmd -Folder \\fileserver\thinclients`.

## Devices: the whole fleet at a glance

The **Devices** page lists every device that reports to the folder, with a coloured dot for its state, the user
signed in, the version it runs and its last report; the search box finds a device by name, address or user. Devices
report every 5 minutes and at boot, and the list refreshes itself every minute. A device that stopped reporting,
rejected the central settings or has a failed service stands out in its colour.

Select a device and its header shows its address, version, last report and user, with its actions: **Remote
screen**, **Logo and background...**, **Software version...**. Under it:

| Tab | What it shows |
|---|---|
| Settings | every setting: the value in use on the device, where it comes from, and the value you set for it |
| Summary | a readable report: session, transport in use (UDP or TCP), network and Wi-Fi, software and FreeRDP, the version it installs, security updates, management, secrets, uptime |
| Events | the event log of the device: sessions, drops with their cause, updates, settings applied or rejected |
| Full report | the status file as the device wrote it |

<p align="center">
<img src="screenshots/manager-pilot.png" alt="A pilot device: the list marks it (pilot), its summary says it installs the newest version" width="100%">
</p>

## Settings for all devices or one

**Common settings** are for every device (`config\common.conf`); in a device's **Settings** tab, tick *Exception*
to give that device a value of its own (`config\<hostname>.conf`), which wins over the common one. Every row shows:

- the value **in use on the device** (from its last report);
- **where it comes from**: the device itself, the common settings, or an exception for this device;
- in orange, ***on its way***: a value you saved that the device has not applied yet. It reads the folder every 5
  minutes; when it stays orange, the device has refused the settings (its state says so).

The help of the selected setting is in full under the list. Before saving, the manager checks every value with the
same rules as the devices (a device refuses a whole configuration with one wrong value), and before saving the
common settings it lists the devices that would refuse them. Every save keeps a copy of the file in
`config\backup\` and adds a line to `config\changes.log`.

<p align="center">
<img src="screenshots/manager-common.png" alt="Common settings: every setting with its value and the help of the selected one" width="100%">
</p>

All the settings: [configuration.md](configuration.md).

## Updates: a few devices first, then all, and back when something breaks

The **Updates** page shows the newest version in the folder, the version all devices are on, the pilot devices,
the devices kept on a version of their own, the versions you can choose, and what the devices run now.

<p align="center">
<img src="screenshots/manager-updates.png" alt="Updates page: newest published version, all devices on 0.2.0, one pilot device on the newest, the versions that can be chosen" width="100%">
</p>

Everything here is one setting, `UPDATE_TO`, written for you in the right file:

| `UPDATE_TO` | where | means |
|---|---|---|
| `latest` | `common.conf` | every device takes each new version as soon as it is in the folder (the default) |
| a version, e.g. `0.2.0` | `common.conf` | every device stays on that version, or **goes back** to it |
| `latest` | `<hostname>.conf` | a **pilot device**: it takes the newest version even while the others stay |
| a version | `<hostname>.conf` | that device stays on, or goes back to, its own version |

A device installs a version also when it is **older** than its own, FreeRDP included, and installs nothing newer
until the setting changes. As always, an update never interrupts a session: it is installed in the background and
applied when the session is over.

### Try a new version on a few devices

1. **Choose the pilots.** In the header of a device, **Software version...** > *pilot device*. Pick devices that
   look like the rest of the fleet (the same model, the same kind of user), and users who will tell you when
   something is odd. The list marks them *(pilot)*.
2. **Bring the new version in for the pilots only.** **Release from GitHub...** (top bar or Updates page) downloads
   the latest release, checks its project signature and hash, and asks: *all devices* or ***pilot devices only***.
   With pilot only, all the other devices are first kept on the version they have (`UPDATE_TO=<that version>` in
   `common.conf`), and only then the new version goes into the folder.
3. **Watch the pilots** for a few days: their **Summary** and **Events**, and the **Problems** page.

### Release it to the whole fleet

When the pilots are fine: **Updates > Release to all devices**. `common.conf` goes back to `UPDATE_TO=latest`
and every device takes the new version within 5 minutes, each one when its session is over.

### Something broke: go back

- **The whole fleet:** **Updates > Version for all devices...**, choose the version that worked (newest first, from
  `updates\versions\`). Every device goes back to it, FreeRDP included, and stays there.
- **One device:** **Software version...** in its header > *its own version*.
- **A version that is no longer in the folder:** **Version from GitHub...** fetches it (the release `v<version>`,
  with the same checks) into the folder, without changing what the others get.

When the fix is out, **Release from GitHub...** again, pilots first, and **Release to all devices**.

**Good to know**

- Devices go back only to **0.2.0 or later**: older versions do not know `UPDATE_TO`.
- Devices that still run a version **before 0.2.0** ignore `UPDATE_TO` and take the newest version in the folder.
  The manager names them before a pilot-only release: the first time, release 0.2.0 to all devices, or update those
  devices first.
- With `UPDATE_FROM=github` (no management folder for updates) the same setting works: the devices fetch the release
  `v<version>` from GitHub.
- Every published version keeps its signed index in `updates\versions\`; the newest 3 packages stay in the folder,
  plus every version a device is kept on. Details: [management.md](management.md#pilot-devices-and-going-back).

## Remote screen

**Remote screen**, in the header of a device, shows its screen in your browser and lets you use it: to see what a
user sees, or to sign in once to a web page on a screen with no keyboard.

<p align="center">
<img src="screenshots/remote-screen.png" alt="The screen of a device in the browser, with the notice the device shows" width="80%">
</p>

It goes **through SSH only**, with the key of the manager's vault and a one-time password: nothing new listens on
the network, and nothing is installed on your PC. The device shows *Remote assistance active* while it lasts and
records it in its events; it ends when you close the small window, or by itself after 2 hours. `REMOTE_SCREEN=off`
turns it off. How it works: [management.md](management.md#remote-screen).

## Problems across the fleet

The **Problems** page reads the event logs of every device together, for today, 24 hours, 7 or 30 days, and groups
what went wrong: failed sign-ins (by broker), desktops that did not start, sessions dropped (by cause), sessions
taken over, UDP blocked, failed updates, rejected settings. Each line says how many times, on which devices, for
which users, first and last time. A line is orange when 3 or more devices had the same problem: that points at a
server or the network, not at a device. "Six devices could not reach the broker this morning" is one line instead
of six logs.

## Desktops, brokers and Hyper-V hosts

When a user cannot sign in, the cause is often on the Windows side: a broker that fails every request, a host whose
RDVH agent is stuck, a desktop that is saved or off, a session left disconnected. The **Desktops** page shows that side
next to the devices, for a deployment of Remote Desktop Services with Hyper-V (personal desktops, and session hosts when
there are some).

<p align="center">
<img src="screenshots/manager-desktops.png" alt="Desktops page: who cannot sign in on top, each user with the device, the desktop, its host, the VM, the session and the last sign-in; the selected user with its actions" width="100%">
</p>

- **One row per user and device**: the device, the personal desktop (VM), its Hyper-V host, the state of the VM
  (running, off, saved, not responding), the Windows session (active, idle for how long, disconnected since when) and
  the last sign-in: when, through which broker, and whether it took a second try.
- **Who cannot sign in now** is on top, in red, and named in one line above the list with what stops them. A colour
  never comes alone: the state says it in words.
- **Select a row**: one sentence says what is wrong, then the desktop, the session, the device and the last sign-ins,
  each with the broker that served or refused it.
- **Its actions**: *Shadow* (the screen of the session, with the user's consent unless the policy of the desktop says
  otherwise), *Message...*, *Disconnect*, *Start VM*, *Restart VM*, *Desktop...* (the personal desktop of the user),
  *Log off*, *Shut down VM*. The same on the row with a right click or the menu key. A button that cannot be used now
  is grey, and its tooltip says why.
- **Filters and search**: problems only, signed in, disconnected, VM off or saved; a user, device, desktop or host.
- The brokers and hosts are read **in the background every 2 minutes** (and with *Refresh*); the page says when. A
  host that does not answer never holds the window.

### Brokers and hosts

The **Problems** page starts with the brokers, the shared name the devices use, and the Hyper-V hosts: one line each,
green when healthy, otherwise one sentence and, when a safe fix exists, its button. A right click on a broker or a host
gives all its actions.

<p align="center">
<img src="screenshots/manager-brokers.png" alt="Problems page, Brokers and hosts: a host without the permission of a broker, a broker that fails every sign-in, VMs with a vTPM that the cluster would save, a broker without self-repair, each with its Fix button" width="100%">
</p>

| It checks | Fix |
|---|---|
| **Each broker**: sign-ins received and failed since midnight (or since its service started), and the last ones. A broker that fails every request it receives is an error even when it receives few: users get in at the second try, through another broker, and nobody reports it. Its known signature (it presents itself to itself without the `$` of its computer account, event 4648 of `tssdis.exe`) is named | **Restart**: Tssdis, TScPubRPC and RDMS stop and start again, Tssdis first, with time limits, a hanging process is ended; then its Kerberos tickets are purged |
| Its services, also those stuck in *StopPending* | **Restart** |
| Its database (events 2048, 2072) | |
| The **self-repair** task (below) | **Install** |
| The broker in the AD group of the settings | **Add** |
| **The shared name** (`BROKER` of the devices): every broker behind it, every address answering on port 3389 | |
| **Each host**: every broker in *RDS Endpoint Servers*, *RDS Management Servers* and *Hyper-V Administrators*, directly or through a group (nested groups too). The RDVH agent moves between brokers by itself: a missing permission breaks one broker at random | **Repair**: the AD group of the settings (or the broker's computer account) into the groups that miss it, then the tickets of the brokers |
| *VmHostAgent* and *vmms* stuck, the RDVH agent attached to no broker or with no broker to attach to | **Unblock**: the service stops with a time limit, its process is ended if it hangs, it starts again |
| VMs with a vTPM that the cluster would **save** when it stops them (`OfflineAction` 1): they may not start again | **Correct**: `OfflineAction` 2, shut down |

### Safe by design

- Every action asks first, saying exactly what will happen and to whom (*Signed in there: alice. Her open programs
  close without saving*; for those, *No* is the default), and goes into `config\changes.log` like every other change.
- A broker is restarted only while another one is healthy, and never two at once; one action at a time.
- VMs are shut down (Windows closes inside them), **never saved** and never switched off; a VM of the cluster starts as
  a cluster role.
- What stops or ends something is not offered on data older than 5 minutes: *Refresh* first.
- `OTR_MANAGER_VDI_DRYRUN=1`: every action says what it would run, and runs nothing.

### What it needs

- The manager started as an account that administers the brokers and the Hyper-V hosts, with **WinRM** (port 5985)
  open from the PC to them. The sessions are read from the desktops as `quser` reads them (remote RPC, allowed on a
  Windows 10/11 desktop by `AllowRemoteRPC`); log off, disconnect and message fall back to WinRM on the desktop.
  Without the rights, the page says so in one sentence and the rest of the manager works as before.
- Nothing to configure in most cases: the brokers come from `BROKER` and `BROKER_FALLBACK` of the devices, the active
  management server of the deployment names the other brokers, the hosts and the desktops, the clusters name their
  nodes. **Settings...** on the page (kept for your account on your PC, not in the folder): the **AD group of the
  brokers** (the hosts give their permissions to it, never to single computers), more brokers or hosts if they are not
  found, or the page turned off.
- How it reads them, and why not the RemoteDesktop cmdlets (blind on any server but the active management server): the
  comments at the top of `management/windows/OtrVdi.ps1`.

### Broker self-repair

A broker can start failing every sign-in after it leaves and joins the farm again: it presents itself without the `$`,
falls back to NTLM, and every request ends with *access denied* (event 804, `0x80070005`) until its services start
again. `management/windows/rds/Broker-SelfRepair.ps1` does that by itself, as a scheduled task started by the event
of that fault, at most once every 15 minutes. **Install** in Brokers and hosts installs or updates it; by hand:
`Install-BrokerSelfRepair.ps1 -Broker rdcb1.example.com, rdcb2.example.com` (`-Remove` takes it away). A broker that
already has a self-repair task of its own is left as it is.

## Vault, keys and the site key

Two keys rule the fleet: the SSH key that opens the screen of any device, and the key that signs the update packages
every device installs. The manager keeps both in `vault.otr`, next to it, encrypted with an **access code** that only
the administrators know. Every administrator who starts the same copy opens it with the same code; without the code
the settings can still be edited, but no screen opens and nothing is signed.

<p align="center">
<img src="screenshots/manager-vault.png" alt="Vault page: the access code, the SSH key of the manager, the key that signs the updates" width="80%">
</p>

**A fleet on its own key.** With `UPDATE_KEY=site` your devices accept only updates signed by the key of your site,
which exists only in your vault. The manager checks each GitHub release (project signature and hash) and signs it
again with your key: a stolen project key installs nothing on your fleet. Set it up step by step:
[management.md](management.md#a-fleet-on-its-own-key).

## Logo, background, SSH keys, permissions

- **Logo and background...** (common settings, or a device): any picture, scaled and saved as PNG, for every device
  or one.
- **SSH keys**: the keys of the administrators, sent to every device (`SSH=on`); **Add the key of the manager** puts
  the vault's key there for the remote screen.
- **Check permissions** tells you what the account of the devices can do in the folder: it needs to write only its
  status, never the settings or the updates.
- The window fits any screen, from a 27" monitor to a laptop with display scaling (down to 860×560).

## The manager updates itself

Every release carries the manager of the same version, under the same signature as the update package. At start,
in the background, the manager checks the latest release; when there is a newer manager, the top bar shows
***Manager X available***. **Update the manager** downloads it, checks signature and hash, keeps the files it
replaces in `previous\`, and starts again. Your `vault.otr`, the launcher and anything that is not part of the
manager stay as they are; if anything fails, the previous files come back.

Update the copy the administrators start (on a share, from a PC that can write there): everybody who starts it gets
the new version. The **Updates** page shows the manager's version and has **Check again**. Details:
[management.md](management.md#the-manager-updates-itself).

## Starting it, and the command line

- `OpenThinRDP-Manager.vbs` starts it without a console window; `build-launcher.ps1` makes an `.exe` with the
  OpenThinRDP icon to pin to the taskbar, and with `-Install` a shortcut on each PC that starts the copy on the share
  ([details](management.md#central-settings)).
- `OpenThinRDP-Manager.cmd -Folder \\fileserver\thinclients -Language en|it`: the folder and the language (by default
  the Windows display language).
- `OpenThinRDP-Manager.cmd -Sign <folder>\LATEST.txt`: signs an update package you built with `make-update.sh`, with
  the key in the vault ([Signed updates](management.md#signed-updates)).
- `OpenThinRDP-Manager.cmd -UpdateManager`: updates the manager without a window (exit code 0 = updated, 1 = error,
  2 = nothing to do).

What is in the folder, file by file, and how the devices use it: [management.md](management.md).
