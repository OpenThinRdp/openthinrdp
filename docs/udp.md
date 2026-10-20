# UDP transport

Windows sends Remote Desktop graphics over UDP when the client supports MS-RDPEMT/RDPEUDP. Over TCP a busy
server or a lossy line makes the screen fall behind: every lost packet holds up everything after it. Over UDP
the server measures the line and lowers frame rate and quality instead, so the session stays responsive.

The UDP transport is part of FreeRDP since [pull request #13608](https://github.com/FreeRDP/FreeRDP/pull/13608),
which came out of this project, but upstream ships it switched off. OpenThinRDP ships FreeRDP with it switched on,
so it works out of the box.

## What travels over UDP

With the UDP transport Windows moves the dynamic virtual channels onto the reliable UDP tunnel (with Soft-Sync):
graphics, USB redirection, audio, camera, input and the other dynamic channels. The static channels stay on the
TCP connection: clipboard, drive redirection (smart cards and serial ports included) and printing. The TCP
connection also carries sign-in and licensing and is always needed, also with `TRANSPORT=udp`: if it drops, the
session drops.

A USB stick passed whole over the UDP tunnel moved 1 GiB each way and 4000 small files each way, all with the
same SHA-256 at both ends.

## Modes

`TRANSPORT`, per device or for all of them (settings dialog, central settings, manager):

| Value | Behaviour |
|---|---|
| `auto` (default) | UDP. When UDP is blocked, or fails during the session, FreeRDP goes on over TCP; the next connection tries UDP again |
| `udp` | UDP only. A connection that runs without UDP for 30 s is closed and opened again; after 3 in a row the device shows "UDP not available". For networks where UDP is known to work, and for testing |
| `tcp` | TCP only |

The kiosk runs FreeRDP with `/network:auto` for `auto` and `udp`, and with `-multitransport` for `tcp`. It does
not use `/auto-reconnect`: when FreeRDP's own reconnection fails it exits with the same code as an
administrator disconnect, and the device would stop. The kiosk reopens the session itself instead.

The `status\<hostname>.txt` line `TRANSPORT=auto (in use: udp)` shows what the session really uses.

## Server side

Nothing to install. UDP must be allowed:

- Group Policy *Computer Configuration > Administrative Templates > Windows Components > Remote Desktop Services
  > Remote Desktop Session Host > Connections > Select RDP transport protocols*: not configured, or "Use both
  UDP and TCP".
- UDP port 3389 open on the session hosts (Windows opens it by default) and on any firewall in between. The
  broker does not need it: it only redirects.

## On a lossy line

Loss emulated with netem on the thin client, on the traffic from the virtual machine only, raised step by step
until the session gave up. Windows 11 VDI behind the broker, full-screen
load that changes every pixel at 30 frames per second; frame rate and loss as reported by the server; 90-120 s per
step.

| packets lost | OpenThinRDP over UDP | TCP, same line and load |
|---|---|---|
| 0% | 15-21 fps | not measured |
| 5% | not measured | 7-12 fps |
| 10% | not measured | 6 fps |
| 20% | not measured | **0.6 fps**, the screen barely moves |
| 30% | not measured | 0.2 fps, 26 frames a second dropped by the server |
| 50% | **19-21 fps** | not measured (already at 0.2 fps with 30%) |
| 60% | 14-21 fps | not measured |
| **70%** | **18-19 fps**\*\* | not measured |
| 80% | 4 fps, then the tunnel gives up after 18 s | not measured |

\*\* With the FreeRDP of OpenThinRDP 0.1.5 (no 1 s freeze at every wrap of the channel sequence; 9-13 fps
before). At 70% the first thing to give up is the TCP connection that RDP keeps beside the UDP tunnel: after
20 s without an acknowledgement (`/timeout`, set by the kiosk) it ends the session, which happened once after
100 s and not in another run of 150 s.

On UDP no frame was dropped by the server for network reasons up to 70%. A session opened when the line is
already bad is set up over UDP too.

**Limits of these numbers:** one environment (Dell OptiPlex 3000 Thin Client, Windows 11 VDI on Hyper-V behind an
RD Connection Broker), one kind of load, loss emulated with netem on the client. The method and the scripts are
in [tests/udp-bench](../tests/udp-bench/README.md): numbers from other networks and servers are very welcome.

Over TCP every lost packet holds up everything behind it until it is resent; over UDP the lost packets are resent
while the rest of the stream goes on. Getting there took a fix to the UDP transport: after the channel sequence
wrapped, an unsigned difference went below zero, the client believed the stream had been stuck for ages and
ended the connection within 1-25 seconds of the loss starting. We reported it with a fix in the pull request; its
author fixed the root cause there (the client now skips channel sequence 0 like Windows does).

## The FreeRDP in the image

`image/freerdp/freerdp.conf` names the exact source: commit `dda5414` on branch
[`openthinrdp-udp-3.32.2-pr58`](https://github.com/Ceschi-ops/FreeRDP/tree/openthinrdp-udp-3.32.2-pr58) of a
FreeRDP fork, which is the **FreeRDP 3.32.2** release (the security release of 2026-10-12) with the 58 commits of pull
request #13608, the UDP transport, at its head `f54ad1d36`, applied unchanged. Several of those commits came from our
tests: no false "stream is stuck" on lossy lines (see above), ten SYN attempts instead of four (SYN and SYN+ACK are
padded to the MTU, the first packets a bad line loses), run-length ACK vectors, reconnecting through the broker after
its one-time token, and UDP declined only when the connection really goes through an RD Gateway.

On top, nine commits of FreeRDP master that came after 3.32.2:

- The header of bandwidth measure payloads is counted, as mstsc does. With `/network:auto`, which the kiosk passes
  with UDP, Windows otherwise reported a bandwidth of 0 and started every session **5 seconds late**: from the
  broker's redirect to the desktop took 5.1 s, now 0.13–0.18 s.
- `/network` is applied before the other options (ours, [#13748](https://github.com/FreeRDP/FreeRDP/pull/13748)).
  Without it `/network:auto` turned on the H.264 codecs that `RDP_GFX` turns off, and the server encoded the whole
  desktop with AVC444 (0.1.12).
- The microphone keeps capturing when the server changes only the bit rate (ours,
  [#13751](https://github.com/FreeRDP/FreeRDP/pull/13751)). Windows 11 switches between AAC entries several times a
  second, and every switch closed and reopened the capture: the other end of a call heard gaps.
- RD Gateway: a possible out-of-bounds read, RDG packet handling, a partly read header (five commits).
- USB: a failed kernel driver detach no longer stops the redirection (two commits).

FreeRDP 3.32.2 already contains the USB fixes found while building OpenThinRDP: #13674 (deadlock between USB hotplug
and the closing of the USB channel) and #13679 (from our #13677: no hang on disconnect with a USB transfer pending),
plus #13618 (no real USB device reset). When the UDP transport reaches a FreeRDP release, the image goes back to
Debian's packages.

The packages are built by `image/freerdp/build-debs.sh` (Debian's trixie-backports packaging, with
`-DWITH_RDPEUDP=ON`). The image build downloads the prebuilt ones from the release named in `freerdp.conf`
and checks them against `image/freerdp/SHA256SUMS`, or builds them when that file is missing. To use Debian's
FreeRDP instead (TCP only), set `FREERDP_FROM=backports` in `build.conf`.

## Reporting

Problems with UDP itself (a session that freezes, drops, falls back to TCP) are worth reporting upstream,
in the pull request thread, with:

- the FreeRDP log of the session (`/tmp/kiosk.log` on the device; for a session that dropped,
  `/tmp/kiosk.log.prev`) and the events (`status\<hostname>-events.log` in the management folder: the DROPPED
  event ends with FreeRDP's last error);
- what the network was doing (Wi-Fi, VPN, loss), and the Windows version of the session host.

Problems with the kiosk or the image: issues in this repository.
