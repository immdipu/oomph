# Contributing to Oomph

Thanks for helping make Oomph better. This guide covers how to build it, how the code is
organized, and what a good change looks like.

## Before you start

- **Bugs**: search the [issues](https://github.com/immdipu/oomph/issues) first, then file one
  with the bug template. Include `eqtune status` output; it answers most questions.
- **Features**: open an issue to talk it through before writing a lot of code. Oomph is a front
  end for [eqtune](https://github.com/y7nieSEl5/eqtune), so anything that needs new audio
  processing (per-app EQ, new filter types, a spectrum analyzer) starts as an eqtune feature.
- **Engine problems** (audio dropouts, a device that won't process, CPU use) usually belong in
  [eqtune's issues](https://github.com/y7nieSEl5/eqtune/issues).

## Building

You need macOS 14.2 or later on Apple Silicon, Xcode 16 or later, and Rust from
[rustup.rs](https://rustup.rs).

```bash
git clone --recurse-submodules https://github.com/immdipu/oomph.git
```

```bash
cd oomph && xcodebuild test -project Oomph.xcodeproj -scheme Oomph -destination 'platform=macOS,arch=arm64' -derivedDataPath build
```

The first build compiles eqtune's Rust crates (about a minute). To build without your signing
identity, add `CODE_SIGNING_ALLOWED=NO` to the `xcodebuild` command, as CI does.

## How Oomph is put together

- **Oomph never processes audio.** Every action is an `eqtune` command, and the UI shows only
  what eqtune reports. Don't cache engine state in the UI; read it from `EqtuneStore`.
- **All CLI calls go through `EqtuneStore`**, one at a time, and every state-changing command
  re-reads `status` afterwards. Add new commands there, next to the ones they resemble.
- **eqtune identifies bands by frequency** (within 0.5 Hz). Moving a band is an add plus a
  remove, and two bands can't share a frequency. `EqtuneStore.editBand` and
  `Preset.freeFrequency(near:)` handle this; reuse them.
- **eqtune's text output isn't a stable API.** Parsers are written against the captured output
  in [Docs/cli-samples.md](Docs/cli-samples.md) and `OomphTests/Fixtures`. When eqtune is
  updated, recapture those first.

## Code style

- Swift 6 with strict concurrency, SwiftUI, and no third-party dependencies. Please keep it
  that way unless an issue agrees otherwise.
- Match the code around you: four-space indentation, small types, and comments that say
  *why*, not *what*. Doc comments describe behavior in plain sentences.
- User-facing text is plain and friendly: say what happens in the words a listener would use
  ("Loud parts may distort"), not engine jargon. Use typographic quotes (“ ”) and apostrophes (’).
- Shared building blocks live in `Oomph/UI/Components.swift`: `Format` for numbers,
  `FailureBanner` for errors, `SectionHeader`, `ValueSlider`. Use them so screens stay consistent.
- Every control needs an accessibility label if its text doesn't already say what it does.

## Tests

Use [Swift Testing](https://developer.apple.com/documentation/testing). Logic gets a test:
parsers, DSP math, and the commands the store sends (against `MockEqtuneClient`, never the
real daemon). Pure UI layout doesn't need one, but check it in light and dark mode.

## Pull requests

1. Branch from `main` and keep each pull request to one change.
2. Run the tests and build with no warnings.
3. Update [CHANGELOG.md](CHANGELOG.md) under *Unreleased* for anything a user would notice.
4. Fill in the pull request template, with before/after screenshots for UI changes.

Commit messages: a short summary in the imperative ("Add a preset per output device"), then a
body explaining what changed and why.

## Releasing

Pushing a version tag runs the [release workflow](.github/workflows/release.yml). It builds
Oomph with `Scripts/release.sh`, which signs the app and its bundled engine with a Developer ID
and notarizes and staples both the app and the disk image. The workflow then publishes
`Oomph-<version>.dmg` on a GitHub release, with that version's CHANGELOG section as the notes.

1. In CHANGELOG.md, move the *Unreleased* entries under a new `## [1.1.0] - YYYY-MM-DD`
   heading. The workflow stops if the tag's version has no section.
2. Commit and push, then tag: `git tag v1.1.0 && git push origin v1.1.0`. The tag sets the
   app's version.

The workflow needs these repository secrets (Settings › Secrets and variables › Actions):

| Secret | Value |
|---|---|
| `DEVELOPER_ID_CERTIFICATE_P12` | A *Developer ID Application* certificate and its private key, exported from Keychain Access as a .p12, base64-encoded: `base64 -i Certificates.p12 \| pbcopy`. Only the developer account's Account Holder can create the certificate. |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password you gave the .p12 when exporting it. |
| `NOTARY_KEY` | The contents of an App Store Connect API team key (.p8) with the Developer role, from Users and Access › Integrations in App Store Connect. |
| `NOTARY_KEY_ID` | That key's Key ID. |
| `NOTARY_ISSUER_ID` | The Issuer ID shown above the list of keys. |

To check a release build without notarizing or publishing it, run the script with your own
signing identity:

```bash
SIGN_IDENTITY="Apple Development" Scripts/release.sh 1.1.0
```

If notarization fails, the workflow's log shows the submission ID, and
`xcrun notarytool log <id>` with the same key shows why.

## Code of Conduct

This project follows the [Contributor Covenant](CODE_OF_CONDUCT.md). Be kind.
