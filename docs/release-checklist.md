# Release checklist

A version is published only when every point below holds. A known defect is never published: it is fixed first.

1. **One pull request per change**, merged only with the CI green (system tests in a Debian 13 container, manager
   tests on Windows PowerShell 5.1).
2. **The tests on the build machine** again, on the commit to release: `tests/run-tests.sh` in a clean
   `debian:trixie` container, the tests of the manager in its repository (openthinrdp-manager-src).
3. **On real hardware**, for what the release touches: a thin client of the production fleet for the kiosk,
   sessions, USB and updates; the manager on the real management folder, every page drawn.
4. **The anonymous error counts** of the version before ([privacy.md](privacy.md)): the new one must not bring back
   a problem that was gone.
5. **A major update?** (a change to how a session connects or runs): the file `MAJOR` set to the version and the
   entry of the [CHANGELOG](../CHANGELOG.md) marked **Major update**. Devices with a management folder then install
   it only once the manager released it, with a second confirmation.
6. **The CHANGELOG** says what changed in words an administrator understands, with what to do when something must
   be done.
7. **Signed** with the project key on the build machine (`make-update.sh -k`), checked with `gpg --verify`, and the
   release created on GitHub with the update package, the manager, `LATEST.txt` and its signature.
8. **After**: the site rebuilt, [known issues](known-issues.md) updated, and the issues it fixes answered.
