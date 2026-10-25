# Maintainers

| Who | What |
|---|---|
| [Ceschi-ops](https://github.com/Ceschi-ops) (IT of Finco Agricoltura, Italy) | everything: code, releases, the release signing key, the site |

**Plainly:** OpenThinRDP has one maintainer today. It was born to run the thin clients of a company that uses it
every day, and that company keeps it going. We would like a second maintainer: if you run OpenThinRDP and would help
review and release, say so in the [discussions](https://github.com/OpenThinRdp/openthinrdp/discussions).

**If the maintainer can no longer act:** the code is all here, under the GPL, and anyone can fork it and go on. The
release signing key is kept at Finco Agricoltura on the build machine and offline on a recovery disk, its
revocation certificate offline apart from it (see [SECURITY.md](SECURITY.md#custody-of-the-key)); a new maintainer can be given the key, or a new key published with a
release signed by the old one. A fleet on its own site key ([management.md](docs/management.md#a-fleet-on-its-own-key))
does not depend on the project key at all.

How changes and releases are made: [CONTRIBUTING.md](CONTRIBUTING.md) and the
[release checklist](docs/release-checklist.md).
