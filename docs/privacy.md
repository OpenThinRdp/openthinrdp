# Privacy: the anonymous data

OpenThinRDP is free, and anonymous data is how we learn which computers it runs on, how it is set up and used, how
well it runs and what goes wrong, so we know what to fix and what to support first. You choose how much is sent, and
this page lists all of it, item by item. Nothing on it can tell who you are, where you are or what you do in a session.

## Three levels

| Level | What is sent |
|---|---|
| **Full** (the default) | Once a week what the device is, how it is set up and used, how well it runs, and what went wrong |
| **Errors only** | Only in a week when something went wrong: what went wrong, on which version and computer |
| **Off** | Nothing |

A new device asks at its first start, with *Full* ready and the three levels explained on the screen; nothing leaves
it before the answer. Later: *Anonymous data for the project*, the last setting of the device, or `ANON_STATS` (`full`,
`errors`, `off`) for a whole site or group from the manager. The manager has the same three levels for itself
(*Settings > Manager*). Devices and managers that sent anonymous counts before 0.3.3 and manager 1.1.7 send *Full*.

`sudo /opt/openthinrdp/stats.sh --print` on a device prints exactly what it would send now, and sends nothing.

## What a device sends

Once a week (`stats.sh`, started by `report.sh`); the first time once its level is chosen.

**The week** (`otr_week`, *Full* only):

| What | Example |
|---|---|
| OpenThinRDP and FreeRDP versions | `0.3.3`, `3.33.0` |
| Maker and model, processor, memory in GB, architecture | `HP t530 Thin Client`, `AMD GX-215JJ`, `4`, `amd64` |
| Live system or installed, language | `live`, `it` |
| First send of this device | `yes` / `no` |
| Wi-Fi adapter, TPM, managed from a management folder | `yes` / `no` |
| Domain or workgroup; a broker or one computer | `workgroup`, `pc` |
| RD Gateway; kind of VPN; where updates come from; transport | `no`, `tailscale`, `github`, `auto` |
| Password remembered, Wake-on-LAN, a Bluetooth device paired | `on`, `yes`, `no` |
| Connected by cable or Wi-Fi | `cable` |
| Web button and the browser chosen | `app`, `firefox` |
| Screens: how many, class of the widest, resolution and scale chosen | `2`, `4k`, `native`, `auto` |
| Kinds of USB devices plugged in (never which ones) | `camera`, `smart-card`, `audio`, `storage`, `printer` |
| Installed alongside Windows; a live stick that keeps its settings | `yes` / `no` |
| Sessions, days used, hours in session, sessions over UDP and over TCP | `12`, `5`, `31.5`, `10`, `2` |
| Seconds from power on to the sign-in screen; sign-in in seconds, by step (broker, virtual machine, Windows) | `38`, `4.2` |
| Latency of the sessions (median, ms) | `12.5` |
| How many kinds of problems | `0` |

**What went wrong** (`otr_errors`, *Full* and *Errors only*, only in a week with something wrong): the version,
model, processor, memory, FreeRDP, live or installed and language as above, and

| What | Example |
|---|---|
| A session that froze and was ended by the watchdog | `session-frozen` |
| A session that dropped, with the exit code of FreeRDP | `session-dropped`, code `147` |
| A connection that failed or got no desktop in time, with the code | `connect-failed`, code `131` |
| A UDP transport that stalled; a power off with a session open | `udp-stalled`, `switched-off-in-session` |
| A software update that failed; the settings screen that failed | `update-failed`, `screen-failed` |
| A program that crashed, by its name | `crash`, `xfreerdp3` |
| The graphics stuck, an error of the kernel | `graphics-hang`, `kernel-error` |
| A stop that was no shutdown (a power cut, or frozen and switched off by hand) | `stopped-without-shutdown` |
| A check of the hardware test that failed, by its name | `hardware-test-fail`, `ip-address` |
| No graphics driver or no sound card, from the same test | `hardware-test-warn`, `sound` |
| A firmware file the computer asked for and the system lacks, by its file name | `missing-firmware`, `iwlwifi-8265-36.ucode` |

Each kind with how many times it happened since the last send. Only the kind, the number of a code, the name of a
program, the name of a check of the hardware test and the name of a firmware file leave the device, never the text of
a message: those hold user and server names.

## What the manager sends

Its first start shows, once, what the manager and the devices send and where each is set. Half a minute after it
starts the first time, then once a day while it is used.

**The day** (`manager_day`, *Full* only):

| What | Example |
|---|---|
| Manager version, Windows, language of the window | `1.1.7`, `Windows Server 2025 Datacenter`, `it` |
| How many devices it manages, in ranges | `1-5`, `6-20`, `21-100`, `more than 100` |
| The size of what it reads, as counts: hosts, VMs, clusters, domain controllers, servers, brokers, SQL replicas, iDRAC, Proxmox, vCenter, Veeam, Citrix, custom checks | `2`, `22`, `1`, `2` |
| The pages opened and the actions used since the last send, by their fixed names, with how many times | `health: 3`, `vm.start: 1` |

**What went wrong** (`manager_errors`, *Full* and *Errors only*, only on a day with errors): version, Windows,
language and devices as above, and how many errors the manager and its window wrote in their logs. Never what they say.

**Feedback** (`manager_feedback`): once a week, until it is sent, the manager asks how it is going (also from
*Settings > Manager > Send feedback*). Only when you press *Send*, and only these: the vote (1 to 5) and what it is
used for, if chosen (`home`, `office`, `trying`). The words you write are not sent by the manager: it opens a
discussion on GitHub already written, in your browser, and you decide whether to post it (with your GitHub account, in
public). *Later* asks again in a week. Nothing when the anonymous data are off.

## What is never sent

The name of a device or of a computer, IP or MAC addresses, user names, passwords, the domain, the names or addresses
of servers and brokers, settings, the text of logs and error messages, anything typed on a device, anything shown in
a session.

## Where it goes

To [PostHog](https://posthog.com/) in its European cloud (Frankfurt). The project is set to keep no IP address; each
send carries a random identifier made for it alone, kept nowhere and taken from nothing of the device or of you, no
person profile and no place from the address. The project sees totals and averages, such as *HP t530: 12 devices,
sign-in 4.2 s*, never a device followed over time. Devices before 0.3.3 and managers before 1.1.7 sent fewer counts
to GoatCounter, also without any IP address.

## What stays at your site

Not sent anywhere, but worth knowing: to show the *experience* (0.2.23), each device writes in its event log how long
each sign-in took (with the user name) and the latency and bandwidth of each session, and the manager keeps these
40 days in `health\experience\` of the management folder. They are technical data of the service, readable by whoever
reads that folder; in some countries measuring the work of employees has rules of its own (in Italy art. 4 of the
Statuto dei lavoratori): tell the users, as for the other logs of the fleet.

## Choosing or switching it off

- **One device**: *Anonymous data for the project*, the last setting of the device: *Full*, *Errors only* or *Off*.
- **Every device of a site**: the same setting in the manager, last in the *Settings* of the site (or of a group), or
  `ANON_STATS=off` (or `errors`) in `common.conf`.
- **Before the first start**: `ANON_STATS=off` in `image/site/site.conf` of your own image: the question is not asked
  and nothing is ever sent. `ANON_STATS` in `common.conf` holds from the moment a device has taken the central
  settings: a new device sends its first data, with the level chosen on its screen, before that.
- **The manager**: *Settings > Manager > Anonymous data for the project*.

When it is off, nothing is sent. A device with no internet sends nothing and tries again at its next report.
