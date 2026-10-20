# Contributing

Thank you for trying OpenThinRDP. The most useful contribution right now is simple: **run it on your hardware
and tell us what happened**, good or bad.

## Reports

- **Something does not work**: open a [bug report](https://github.com/OpenThinRdp/openthinrdp/issues/new/choose).
  Say which device (model, CPU, network card), which version (`SOFTWARE=` in the status file or the ℹ button of
  the sign-in form), and the Windows side (broker or PC, Windows version, VDI or session host).
  The ℹ diagnostics and `/var/log/openthinrdp/events.log` usually say a lot.
- **It works on your device**: a line in
  [Discussions](https://github.com/OpenThinRdp/openthinrdp/discussions) with the model helps others, and goes
  into [docs/hardware.md](docs/hardware.md).
- **UDP itself** (the FreeRDP transport): the [FreeRDP#13608](https://github.com/FreeRDP/FreeRDP/pull/13608)
  thread is the right place, with a FreeRDP log if you can.
- **Security problems**: never in a public issue, see [SECURITY.md](SECURITY.md).

Remove from logs and screenshots what you do not want public: domain, server names, user names, addresses.

## Code

1. Fork, make a branch, keep the change focused (one fix or feature per pull request).
2. Follow the style of the file you touch: shell scripts in `rootfs/opt/openthinrdp` are plain bash for Debian 13,
   comments explain *why*; the Windows manager is PowerShell 5.1 (no newer syntax), every text in
   `management/windows/lang/*.psd1`.
3. A new setting goes into `defaults.conf` (with a comment), `save-config.sh` (validation), the manager
   (`New-Setting` and its texts), [docs/configuration.md](docs/configuration.md), and a test.
4. Run the tests: `docker run --rm -v "$PWD":/src:ro debian:trixie bash /src/tests/run-tests.sh`.
   For the image: `image/build.sh` and a try in a VM or on a device ([docs/building.md](docs/building.md)).
5. Describe in the pull request what you tested and on what.

Translations are welcome: one file in `rootfs/opt/openthinrdp/lang/` and one in `management/windows/lang/`
(see the comments at the top of the English files).

By contributing you agree that your contribution is licensed under the GNU GPL version 3 or later, like the project.
Please follow the [code of conduct](CODE_OF_CONDUCT.md).
