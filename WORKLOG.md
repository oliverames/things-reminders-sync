# Worklog

## 2026-11-09: v0.1.0, first public release

- Tag `v0.1.0`; the asset is `ThingsRemindersSync-0.1.0.zip`, with SHA-256
  `a5084112fb06b1f4817bd98a30131f7e5ab7d1fbdcad7edd1f2c9ac0ea895830`.
- Signed with `Developer ID Application: Oliver Ames (84M4ZF255G)`.
  Notarized with the Ames Consulting App Store Connect API key, and Apple
  accepted it (submission `ae786363-f8ab-4b83-82e0-6e3eb28badb1`). Built with
  `scripts/release.sh`.
- Verified the published asset itself: the downloaded zip passes
  `spctl --assess` as "Notarized Developer ID", `stapler validate` succeeds,
  the version reads 0.1.0, and the release checksum matches the local one.
- The always-on Mac now runs the released build, which is signed by
  84M4ZF255G, and `build-app.sh` defaults to that identity, so later deploys
  keep the same signature. Changing the signing team invalidates the Keychain
  item's access list. An SSH session can't write to the login Keychain, so the
  item was re-added from the GUI session with a one-shot LaunchAgent that runs
  `security add-generic-password -T <app>`, with the password passed in a
  temporary file that is deleted afterwards. After that, the app read the item
  with no prompt and synced a title change.
