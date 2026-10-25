# Security policy

Please **do not** report security problems in public issues.

Use GitHub's private reporting instead: on the repository page, **Security** → **Report a vulnerability**.
Describe what an attacker can do, on which version, and how to reproduce it. You will get an answer as soon as
possible; fixes are released as a new version and announced in a security advisory, crediting you if you wish.

Supported versions: the latest release only.

## FreeRDP security fixes

OpenThinRDP ships its own FreeRDP build (the UDP transport is not in a FreeRDP release yet), so Debian's
security updates do not cover it: we do. When FreeRDP publishes a security release or a security advisory, an
OpenThinRDP release with the fix comes out **within 7 days**, usually much sooner, after the same tests as any
other release. Example: FreeRDP 3.32.2, a security release, was published on 2026-10-12 at 12:08 UTC and was in
OpenThinRDP 0.1.4 the same day. Debian's security updates for everything else install by themselves
(`SECURITY_UPDATES=on`). When the UDP transport is part of a FreeRDP release, the image goes back to Debian's
FreeRDP packages and their security updates.

What OpenThinRDP protects and its known limits are described in [docs/security.md](docs/security.md).

## Release signing key

Releases (the software updates that devices install with `UPDATE_FROM=github` or from a management folder) are
signed with this OpenPGP key, built into the image as `/opt/openthinrdp/keys/openthinrdp-release.asc`:

```
OpenThinRDP releases <203820048+Ceschi-ops@users.noreply.github.com>
ed25519, fingerprint 8552 734B 5C1B 67D7 C576  F1AB 79B2 3AE6 1CD4 F6AF
```

A device installs nothing whose `LATEST.txt` is not signed by it (or by your own key, for your own packages
in your management folder).

A fleet does not have to trust this key: with `UPDATE_FROM=share` and `UPDATE_KEY=site` its devices accept only the
key of its own site, kept in the vault of its manager, which checks every release against this key and signs it
again ([docs/management.md](docs/management.md#a-fleet-on-its-own-key)). Then a stolen project key installs nothing
there. The revocation certificate of the project key is kept offline, apart from the key.

### Custody of the key

The private key lives only on the build machine of the maintainer at Finco Agricoltura (a virtual machine of its
own, not reachable from the internet), and a copy sits offline on the disaster recovery disk of the same site. It is
used only by `make-update.sh` to sign a release. If the maintainer can no longer act, Finco Agricoltura holds both
copies and can hand the key to a new maintainer, or publish a new key in a release signed by this one
([MAINTAINERS.md](MAINTAINERS.md)).

### Replacing or revoking the key

Devices check signatures with `sqv` against `/opt/openthinrdp/keys/openthinrdp-release.asc`, which may hold
more than one key, and `sqv` honours a revocation stored in the same file. So a key is replaced through the
update channel itself, with no hands on the devices:

1. **Planned replacement.** Release *N*, signed with the old key, ships a key file with the old **and** the new
   public key. From release *N+1* packages are signed with the new key only. Once the devices you care about
   report release *N* or later in their management folder, a later release drops the old key.
2. **Compromised key.** Release *N*, signed with the old key, ships the new public key and the **revocation
   certificate** of the old one (kept offline since the key was created). Devices accept it because it is
   signed by a key they still trust; from then on they reject anything signed by the old key. It is announced
   in a security advisory and here, with both fingerprints.
3. A device that missed release *N* (off for a long time) still trusts only the old key: update it from a
   management folder with release *N*, or reinstall it from a current ISO.

The same steps apply to your own key (`update-key.asc` in your image) for packages you sign yourself.
