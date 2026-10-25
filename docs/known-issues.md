# Known issues

What we know does not work as it should yet, what to do meanwhile, and since when. Fixed issues leave this page
with the release that fixes them (see the [changelog](../CHANGELOG.md)). Seen something that is not here? Open an
[issue](https://github.com/OpenThinRdp/openthinrdp/issues), with the diagnostics of the device
([how](management.md#diagnostics-of-a-device)).

## A session over UDP can stall during a video call

**Seen** twice on the same device (21 and 23 October 2026), in calls with camera and microphone: the pointer still
moved, but the picture, the camera and the microphone stopped, and the server logged that it sent nothing for hours.
The graphics ran on the UDP transport both times.

**Since 0.2.18** the kiosk sees it (FreeRDP sends over UDP and nothing comes back for 60 seconds), closes the session
and opens it again over TCP until the device restarts; the user loses about a minute. **Since 0.2.22** the device
also collects its diagnostics by itself, and the manager counts these events per device (*Problems (7 days)*).

**The cause** is in the UDP transport of FreeRDP, still being looked for. The UDP transport is new in FreeRDP and
still considered experimental there.

**Meanwhile**, for devices that spend hours in video calls: `TRANSPORT=tcp` for them (on the device, or for their
group in the manager).

## The Raspberry Pi is tested only in QEMU

The ARM image starts and works in QEMU, but no real Raspberry Pi 4 or 5 has run it yet. If you have one, a report in
the [discussions](https://github.com/OpenThinRdp/openthinrdp/discussions) helps a lot.

## The manager updates itself only from 0.2.21

A manager older than 0.2.21 offers the new version and waits for *Update the manager*; from 0.2.21 on it updates
itself. Update it once by hand.

## The Mode box of the Health Center page is empty

The mode of the Health Center (diagnosis only, or diagnosis and repair) is set in *Settings > Health Center*; the box
at the top of its page shows nothing. Cosmetic, being fixed.
