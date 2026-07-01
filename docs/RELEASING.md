# Releasing

Release builds are signed with the **Developer ID Application: Nicholas Vance
(3D9SMH4RWM)** identity, notarized, and published as a notarized `.zip` to
GitHub Releases at `nickv2002/transgui`.

Versioning is CalVer with a daily build counter: `YYYY.MM.DD.N`, e.g.
`2026.06.19.1` for the first release cut on June 19 2026, `2026.06.19.2` for a
second the same day. `scripts/next_version.sh` computes this automatically by
scanning existing `vYYYY.MM.DD.*` git tags — no manual version argument needed.

## One-time setup

Not scriptable — requires interactive Apple/GitHub auth. Do this once per machine.

1. **App Store Connect API key** for notarization: App Store Connect → Users
   and Access → Integrations → Keys → generate a key with the "Developer"
   role, download the `.p8` (Apple only lets you download it once). Store the
   `.p8` file and its Issuer ID in 1Password as an item named
   **"App Store Connect API Key File"** in the **Private** vault
   (`nickfam.1password.com` account), with:
   - the `.p8` attached as a file (its filename, e.g. `AuthKey_XXXXXXXXXX.p8`,
     encodes the Key ID — `scripts/notarize.sh` parses it from there)
   - a text field named `issuer id` holding the Issuer ID UUID

   `scripts/notarize.sh` pulls the key **live** from 1Password via the `op`
   CLI on every run — it is never stored in the macOS keychain or written to
   the repo. Each release run will prompt 1Password for unlock/approval. The
   key only ever touches disk as a `0600` file inside a `0700` temp directory
   that's deleted when the script exits (success or failure).

2. Confirm the Developer ID Application certificate is in your login keychain:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

3. Confirm `gh` is authenticated: `gh auth status`.
4. Confirm `op` (1Password CLI) is signed in: `op account list`.

## Cutting a release

```sh
./scripts/release.sh
```

This does, in order:

1. Checks you're on `main` with a clean working tree.
2. Computes the next version (`scripts/next_version.sh`) and writes it into
   `project.yml` (`MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`).
3. Builds and exports a signed Release `.app` (`scripts/build_release.sh`:
   `xcodegen generate` → `xcodebuild archive` → `xcodebuild -exportArchive`
   with `scripts/ExportOptions.plist`, method `developer-id`).
4. Notarizes, staples, and zips it (`scripts/notarize.sh`) into
   `dist/Transmission Remote-<version>.zip`.
5. Generates changelog notes from `git log <prev-tag>..HEAD`
   (`scripts/changelog.sh`), prepending a section to `CHANGELOG.md`.
6. Commits the version bump + changelog, tags `v<version>`, pushes both.
7. Publishes a GitHub Release with the notarized zip attached
   (`gh release create`).
8. Installs the notarized `.app` into `/Applications`
   (`scripts/install_local.sh`), quitting a running instance first if needed.

If any stage fails, the script stops **before** the commit/tag/push, so a
failed build or notarization never leaves a half-released tag.

## Re-running a failed stage

Each script is independently callable — useful if a later stage fails and you
don't want to rebuild from scratch:

```sh
scripts/next_version.sh                  # print the version that would be used
scripts/build_release.sh                 # archive + export only
scripts/notarize.sh <version>             # notarize/staple/zip an existing export
scripts/changelog.sh <version> [prev-tag] # regenerate changelog notes only
scripts/install_local.sh                  # install the notarized build to /Applications
```

After fixing the issue, just re-run `./scripts/release.sh` — `next_version.sh`
is deterministic from the date and existing tags, so it's safe to retry.

## Verifying a downloaded build

```sh
xcrun stapler validate "Transmission Remote.app"
spctl --assess --type execute --verbose "Transmission Remote.app"
```

Both should report success/accepted with no Gatekeeper warning.
