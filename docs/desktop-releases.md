# Desktop releases

GitHub Actions builds the tagged source and publishes a complete GitHub Release
in **the repository running the workflow**. A maintainer's Mac is no longer
required. The release is Apple Silicon macOS only: a signed and notarized DMG and ZIPs,
plus `SHA256SUMS`. Intel, Linux and Windows are not built or released.

## One-time setup

Enable Actions in the repository (including a fork) and allow the workflow's
`contents: write` permission. Add these **repository Actions secrets** under
Settings → Secrets and variables → Actions:

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12_BASE64` | Base64 of a **Developer ID Application** certificate exported with its private key as `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | The nonempty password used when exporting that `.p12` |
| `MACOS_SIGN_IDENTITY` | Full identity, e.g. `Developer ID Application: Your Name (TEAMID)` |
| `APPLE_API_KEY_P8_BASE64` | Base64 of an App Store Connect **team** API key's `.p8` file, authorized for notarization |
| `APPLE_API_KEY_ID` | The API key ID |
| `APPLE_API_ISSUER` | The team API key's issuer UUID |

On macOS, `base64 -i DeveloperID.p12 | pbcopy` and
`base64 -i AuthKey_KEYID.p8 | pbcopy` prepare the two file secrets. Paste each into
its GitHub secret field. `security find-identity -v -p codesigning` lists signing
identities. App Store distribution and Apple Development certificates are not
substitutes for Developer ID Application. This direct-download app does not
require an App Store provisioning profile or a separate GitHub PAT.

The workflow creates a temporary signing keychain, imports the certificate,
stores the notarytool profile there, then removes the keychain in an `always()`
step. Missing secrets stop the run before builds begin. PR packaging checks never
load release credentials.

References: [GitHub's certificate setup](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications),
[Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Publish a version

1. Set the same numeric version in
   `packages/petdex-desktop-native/app.zon` and `app.package.json`.
2. Commit the version and release changes. Ensure native CI and packaging CI pass.
3. From a clean checkout, run:

   ```bash
   bun run release:desktop 0.9.2 --dry-run
   bun run release:desktop 0.9.2
   ```

The example assumes both manifests were changed to `0.9.2`. The command creates
and pushes `desktop-v0.9.2` to `origin`; the tag starts `desktop-release.yml`.
It does not build locally or need Apple credentials on the maintainer's machine.
A failed tag push can leave a local tag; retry `git push origin refs/tags/desktop-v0.9.2`
after checking that it points to the intended commit.

Alternatively, use **Actions → petdex-desktop release → Run workflow**. Select
the branch/commit containing the release code and matching manifests, enter the
tag, and choose whether to keep the result as a draft. If the tag is new, the
workflow creates it at the selected ref after validation. If it exists, it builds
the existing tag's commit. The workflow must be on the default branch for GitHub
to expose manual runs. With GitHub CLI:

```bash
gh workflow run desktop-release.yml --ref main \
  -f tag=desktop-v0.9.2 -f draft=true
```

A manual run creates its tag with `GITHUB_TOKEN`, so it does not start a second
tag-triggered build. Normal tag pushes publish automatically. All build jobs
use the resolved commit SHA. A failure on any platform prevents publication.
After all 4 files pass validation, the publish job generates checksums,
uploads everything to a draft, and only then makes the release public. The job
uses the current GitHub repository, never a hardcoded upstream repository.

For prereleases use `desktop-v0.9.2-rc.1`, `-beta.1`, or `-alpha.1`. Both manifests
remain `0.9.2` because macOS bundle versions are numeric. GitHub marks these
releases as prereleases. Edit the generated release notes in a draft before
publishing it if you need custom notes.

## Retry and verify

Retry a failed workflow run, or manually run it with the **same tag**. Incomplete
drafts are reusable; already published releases are refused to avoid replacing
files people have installed. If a release is already public, increment the
version for a correction. Tag-specific concurrency prevents overlapping runs.
Do not use the old local `--notes`, `--skip-build`, or `--draft` command flags;
release creation is now owned entirely by Actions.

Download `SHA256SUMS` and the assets into one directory, then run
`shasum -a 256 -c SHA256SUMS`.
The macOS build also checks code signatures, stapled tickets, and Gatekeeper
acceptance before uploading. The app is notarized and stapled **before** it goes
into the DMG, and the DMG is then signed, notarized and stapled too. Updates use
the stapled `.app` ZIP; new installs use the DMG and drag Petdex to Applications.

A release in a fork does not redirect petdex.dev or the app's existing upstream
update links to that fork. Download fork releases from the fork's Releases page;
changing the update service is a separate app configuration change.

## Local packaging preview

An ad-hoc-signed preview for inspecting packaging without Apple credentials. Its
DMG/ZIP names contain `-unsigned`; it does not pass Developer ID Gatekeeper
verification and is never published.

Local preview, with Zig 0.16.0, Bun and Python 3.10+ installed:

```bash
make -C packages/petdex-desktop-native sdk
scripts/setup-native-packager.sh
export NATIVE_SDK_PATH="$HOME/.cache/petdex/native-sdk-c0b10d027efa490fc99a3bc7f1cf88b015999d45"
export NATIVE_CLI="$NATIVE_SDK_PATH/zig-out/bin/native"
export NATIVE_PACKAGER_CLI="$HOME/.cache/petdex/native-packager-064ca9890cc0cf8adc198215bd0ddaeb586c220a/zig-out/bin/native"
scripts/sign-macos.sh dist/packaging-preview/arm64 arm64 --unsigned
```

The runtime SDK is pinned identically in native CI and the release workflow; the
release validator rejects mismatched pins. The newer DMG packager has a separate
immutable pin in `setup-native-packager.sh`. DMGs use
[dmgbuild](https://dmgbuild.readthedocs.io/en/latest/settings.html), with every
Python dependency pinned and hash-checked in `macos-packaging-requirements.txt`.
The settings read the existing background, dimensions and icon positions from
`app.package.json`; a Retina TIFF preserves the two background resolutions.
No Finder automation permission or interactive desktop is needed. The old Native
SDK Finder layout patch is no longer required by this release path.
Set `PETDEX_PYTHON` when the default `python3` is not a usable Python 3.10+.
For local Developer ID builds, omit
`--unsigned`, set `SIGN_IDENTITY` and `APPLE_NOTARY_PROFILE`, or provide the
existing `~/.config/petdex-apple/env` API credentials. The latter stores a
`petdex-notary` profile in the default keychain for subsequent notarization.
