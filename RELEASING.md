# Releasing Snug

## Checklist

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`,
   then regenerate the project: `xcodegen`.
2. Archive with the `Snug` scheme (Release config, Developer ID signing,
   hardened runtime) and export the app.
3. Build and notarize the DMG (`Snug-<version>.dmg`).
4. Sign the DMG for Sparkle:
   `sign_update Snug-<version>.dmg` (uses the ED key pair matching
   `SUPublicEDKey` in `Snug/Info.plist`).
5. Create the GitHub release `v<version>` and upload the DMG. The enclosure
   URL format is:
   `https://github.com/Studio-Knowhere-Team/Snug/releases/download/v<version>/Snug-<version>.dmg`
6. Add the new `<item>` to `docs/appcast.xml` (version, build number,
   `sparkle:edSignature`, `length` from step 4).
7. Commit and push to `main`.
8. **Sync `master`.** Versions <= 1.1.2 shipped with `SUFeedURL` pointing at
   the `master` branch's copy of the appcast. Until those installs have all
   updated past 1.1.2, `master` must carry the current appcast or their
   update checks silently return nothing:

   ```sh
   git push origin main:master --force-with-lease
   ```

   Once analytics/issue reports suggest no pre-1.1.3 installs remain, this
   step (and the remote `master` branch) can be dropped.

## Verify

- `curl -s https://raw.githubusercontent.com/Studio-Knowhere-Team/Snug/main/docs/appcast.xml | grep shortVersionString | head -1`
- Same for the `master` URL — both must show the new version.
- Run the previous version locally and trigger "Check for Updates".
