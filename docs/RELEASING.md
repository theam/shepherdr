# Releases

The [Release workflow](../.github/workflows/release.yml) builds on a GitHub-hosted Apple Silicon Mac. It runs the tests, builds an optimized arm64 app for macOS 14+, embeds the tag's version and the workflow run number, signs it with The Agile Monkeys' Developer ID, has Apple notarize the app and the DMG, verifies the app after ZIP extraction, verifies the DMG, and produces SHA-256 checksums.

The `.dmg` includes an Applications shortcut and installation instructions. The `.zip` contains the same `.app`. Both include the SwiftTerm renderer and its MIT notices. Neither package bundles Herdr or needs Xcode on the user's machine. Committed SwiftPM lockfiles pin the dependency revisions.

## Publish a version

Use a stable tag in the exact form `vMAJOR.MINOR.PATCH`. From the reviewed commit on `main`:

```sh
git tag -a v0.1.0 -m 'Shepherdr 0.1.0'
git push origin v0.1.0
```

Use a new version number for each release. The workflow first creates a draft and uploads all assets, then makes the release public and marks it latest. A failed run can leave a draft, which can be resumed using **Actions → Release → Run workflow** with the existing tag. An already-public release is never overwritten; use a new tag for corrections. Besides the [signing credentials](#signing-and-notarization), the workflow only needs GitHub's automatic `GITHUB_TOKEN` with `contents: write`; no personal access token is required.

Update [release notes](RELEASE-NOTES.md) when installation requirements change. GitHub-generated change notes are appended automatically. The build takes its version from the tag, so changing the Xcode project's development version is optional.

## Reproduce packaging locally

On a Mac with Xcode 16+ and its first-launch setup completed:

```sh
bash scripts/package-release.sh v0.1.0
```

Packages are written to `dist/`. The script refuses to overwrite an existing package of the same version. It does not publish anything. `GITHUB_RUN_NUMBER` supplies the bundle build number in CI; local builds use `1`.

Without signing settings the packages get an ad hoc signature, which is fine for testing on your own Mac but not for distribution. To sign and notarize locally, store notarization credentials once (it asks for the app-specific password), then pass the identity:

```sh
xcrun notarytool store-credentials shepherdr-notary --apple-id you@example.com --team-id TEAMID
SHEPHERDR_SIGN_IDENTITY='Developer ID Application: The Agile Monkeys (TEAMID)' \
SHEPHERDR_TEAM_ID=TEAMID SHEPHERDR_NOTARY_PROFILE=shepherdr-notary \
    bash scripts/package-release.sh v0.1.0
```

`SHEPHERDR_SIGN_IDENTITY` takes the name or SHA-1 hash that `security find-identity -v -p codesigning` lists. `SHEPHERDR_NOTARY_KEYCHAIN` points notarytool at a keychain other than the default one, as CI does.

## Signing and notarization

Releases are signed with a **Developer ID Application** certificate of The Agile Monkeys' Apple team, with the hardened runtime and a secure timestamp, and notarized by Apple. The script notarizes and staples the app, packages the stapled app in the ZIP and DMG, then signs, notarizes and staples the DMG. It stops unless Apple answers `Accepted` and the signing team, stapled tickets and Gatekeeper verdict are as expected. Nothing reaches `dist/` before that, so a failed notarization leaves nothing to publish. Downloads then open like any other app from the internet, without the **Open Anyway** exception that earlier ad hoc signed versions needed.

The workflow reads its credentials from the `release` environment (**Settings → Environments**), which only `v*` tags and `main` may deploy to. Without them a release stops before building.

| Name | Kind | Value |
| --- | --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Secret | The Developer ID certificate and its private key, exported as a password-protected `.p12` and encoded in base64 |
| `DEVELOPER_ID_P12_PASSWORD` | Secret | The `.p12` password |
| `NOTARY_APPLE_ID` | Secret | The Apple ID of a team member who notarizes |
| `NOTARY_PASSWORD` | Secret | An [app-specific password](https://support.apple.com/en-us/102654) of that Apple ID |
| `APPLE_TEAM_ID` | Variable | The team ID that the certificate must belong to |

To set up a new certificate:

1. On the Mac that will keep the private key, create a certificate signing request with **Keychain Access → Certificate Assistant → Request a Certificate From a Certificate Authority**, saved to disk.
2. The team's Account Holder issues a **Developer ID Application** certificate from it. Open the `.cer` on the same Mac; `security find-identity -v -p codesigning` must list it.
3. In Keychain Access, export that identity from **My Certificates** as a `.p12` with a strong password, and load the secrets:

```sh
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12_BASE64 --env release
gh secret set DEVELOPER_ID_P12_PASSWORD --env release
gh secret set NOTARY_APPLE_ID --env release
gh secret set NOTARY_PASSWORD --env release
gh variable set APPLE_TEAM_ID --env release --body TEAMID
```

Delete the exported `.p12` afterwards. Never commit certificates, private keys or passwords, and never ask users to disable Gatekeeper.
