# Privacy: the anonymous counts

OpenThinRDP sends a few anonymous counts to the project once a week. They tell us which computers it runs on, which
versions are in use and how many devices a manager looks after, so we know what to test and what to support. It is
on by default, it is easy to switch off, and this page lists everything it sends.

## What a device sends

About a minute after it starts the first time, then once a week (`stats.sh`, started by `report.sh`). A live system
that keeps nothing between starts sends at each start.

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

`sudo /opt/openthinrdp/stats.sh --print` on a device prints exactly what it would send, and sends nothing.

## What the manager sends

Half a minute after it starts the first time, then once a week:

| Count | Example |
|---|---|
| Manager version | `0.2.16` |
| Windows version | `Windows Server 2025 Datacenter` |
| Language of the window | `it` |
| How many devices it manages, in ranges | `1-5`, `6-20`, `21-100`, `more than 100` |

## What is never sent

The name of a device or of a computer, IP or MAC addresses, user names, passwords, the domain, the names or addresses
of servers and brokers, settings, anything typed on a device, anything shown in a session.

## Where it goes

Each value is one count on [GoatCounter](https://www.goatcounter.com/), an open-source web counter that sets no
cookies and keeps no IP address. The project sees totals, such as *OptiPlex 3000 Thin Client: 12*, never a single
device: each count carries no number or name that would tell two devices apart.

## Switching it off

- **One device**: *Anonymous counts for the project* = off, the last setting of the device.
- **Every device of a site**: the same setting in the manager, last in the *Settings* of the site (or of a group), or
  `ANON_STATS=off` in `common.conf`.
- **Before the first start**: `ANON_STATS=off` in `image/site/site.conf` of your own image, and nothing is ever sent.
  A managed device reads the central settings before its first send, so `ANON_STATS=off` in `common.conf` also
  holds for a new device that reaches the management folder.
- **The manager**: *Settings > Manager > Anonymous counts for the project*, untick.

When it is off, nothing is sent. A device with no internet sends nothing and tries again at its next report.
