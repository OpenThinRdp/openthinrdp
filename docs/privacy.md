# Privacy: the anonymous counts

OpenThinRDP sends a few anonymous counts to the project: once a week from a device, once a day from the manager. They tell us which computers it runs on, which
versions are in use and how many devices a manager looks after, so we know what to test and what to support. It is
on by default, it is easy to switch off, and this page lists everything it sends.

## What a device sends

About a minute after it starts the first time, then once a week (`stats.sh`, started by `report.sh`). A live system
that keeps nothing between starts sends at each start. A new device sends its first counts with its own settings,
before it takes the central settings of its site: so we learn which computers OpenThinRDP is tried on. From then on
it follows the central settings.

| Count | Example |
|---|---|
| OpenThinRDP version | `0.2.16` |
| Maker and model of the computer | `Dell Inc. OptiPlex 3000 Thin Client` |
| Processor | `Intel(R) Celeron(R) N5105 @ 2.00GHz` |
| Memory, rounded to whole GB | `8 GB` |
| FreeRDP version | `3.33.0` |
| Transport setting | `auto`, `udp` or `tcp` |
| Language | `it` |
| Live system or installed | `installed` |
| A Wi-Fi adapter present | `yes` / `no` |
| A TPM present | `yes` / `no` |
| Managed from a management folder | `yes` / `no` |

And what went wrong since the last send, so we can see which versions and which computers have problems:

| Count | Example |
|---|---|
| A session that froze and was ended by the watchdog | `session-frozen`, 2-5 times |
| A session that dropped, with the exit code of FreeRDP | `session-dropped`, code `145` |
| A connection that failed or got no desktop in time, with the code | `connect-failed`, code `131` |
| A software update that failed | `update-failed` |
| A program that crashed, by its name | `crash`, `xfreerdp3` |
| The graphics stuck, an error of the kernel | `graphics-hang`, `kernel-error` |
| A stop that was no shutdown (a power cut, or frozen and switched off by hand) | `stopped-without-shutdown` |
| The hardware test found problems | `hardware-test-problems` |

Each kind is sent once, with how many times it happened in ranges (1, 2-5, 6-20, more than 20), and once with the
version and once with the model of the computer. A week with no problem sends `none`. Only the kind, the number of a
code and the name of a program leave the device, never the text of a message: those hold user and server names.

`sudo /opt/openthinrdp/stats.sh --print` on a device prints exactly what it would send, and sends nothing.

## One count per send

The counter tells visitors apart by internet address and program, so the devices of a site, which all leave from the
same address, would count as one. Each send therefore carries a random number made for that send only, at the end of
its program name (for example `OpenThinRDP/0.2.28 (s 3f9a2c1d)`). It is kept nowhere, it is taken from nothing of the
device or of you, and the next send has another: it tells sends apart, never devices over time.

## What the manager sends

Its first start shows, once, what the manager and the devices send and where each is switched off. Half a minute
after it starts the first time, then once a day while it is used (its version, its Windows and how many devices it
looks after change more often than a device does):

| Count | Example |
|---|---|
| Manager version | `0.2.16` |
| Windows version | `Windows Server 2025 Datacenter` |
| Language of the window | `it` |
| How many devices it manages, in ranges | `1-5`, `6-20`, `21-100`, `more than 100` |

## What is never sent

The name of a device or of a computer, IP or MAC addresses, user names, passwords, the domain, the names or addresses
of servers and brokers, settings, the text of logs and error messages, anything typed on a device, anything shown in
a session.

## What stays at your site

Not sent anywhere, but worth knowing: to show the *experience* (0.2.23), each device writes in its event log how long
each sign-in took (with the user name) and the latency and bandwidth of each session, and the manager keeps these
40 days in `health\experience\` of the management folder. They are technical data of the service, readable by whoever
reads that folder; in some countries measuring the work of employees has rules of its own (in Italy art. 4 of the
Statuto dei lavoratori): tell the users, as for the other logs of the fleet.

## Where it goes

Each value is one count on [GoatCounter](https://www.goatcounter.com/), an open-source web counter that sets no
cookies and keeps no IP address. The project sees totals, such as *OptiPlex 3000 Thin Client: 12*, never a single
device: each count carries no number or name that would tell two devices apart.

## Switching it off

- **One device**: *Anonymous counts for the project* = off, the last setting of the device.
- **Every device of a site**: the same setting in the manager, last in the *Settings* of the site (or of a group), or
  `ANON_STATS=off` in `common.conf`.
- **Before the first start**: `ANON_STATS=off` in `image/site/site.conf` of your own image, and nothing is ever sent.
  `ANON_STATS=off` in `common.conf` holds from the moment a device has taken the central settings: a new device
  sends its first counts before that, a device that already has them sends nothing, also after an update.
- **The manager**: *Settings > Manager > Anonymous counts for the project*, untick.

When it is off, nothing is sent. A device with no internet sends nothing and tries again at its next report.
