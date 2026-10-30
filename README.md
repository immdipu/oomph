# Oomph

Oomph is a menu bar GUI for the open-source eqtune CLI by y7nieSEl5.

[eqtune](https://github.com/y7nieSEl5/eqtune) is a system-wide equalizer for macOS that runs as
a background daemon. Oomph puts it in the menu bar: turn the EQ on and off, pick a preset, A/B
it with bypass, and edit bands with a live frequency-response curve. Oomph does no audio
processing of its own. Every action runs an `eqtune` command, and everything on screen is what
`eqtune status` reports.

## Requirements

- An Apple Silicon Mac with macOS 14.2 or later (eqtune's audio engine uses process taps,
  which arrived in 14.2).
- To build: Xcode 16 or later (developed with Xcode 27.1) and the Rust toolchain
  (`cargo`, from [rustup.rs](https://rustup.rs)). Oomph builds its own copy of eqtune from source.

## Build

```bash
git submodule update --init
```

```bash
xcodebuild -project EQTuneBar.xcodeproj -scheme EQTuneBar -configuration Debug -derivedDataPath build build
```

The app is `build/Build/Products/Debug/Oomph.app`; you can also open `EQTuneBar.xcodeproj` and
press Run. Signing uses your "Apple Development" certificate with the team set in the project
(`DEVELOPMENT_TEAM`); change it to your own team before building on another Mac.

The **Build eqtune engine** phase (`Scripts/build-eqtune.sh`) runs
`cargo build --release --locked` on the `Vendor/eqtune` submodule (pinned to v0.7.1), copies the
binary to `Oomph.app/Contents/Helpers/eqtune`, signs it with the app's identity (Hardened
Runtime) and copies eqtune's licenses to `Contents/Resources/Licenses`. The first build compiles
eqtune's crates and takes about a minute; after that cargo has nothing to do. If `cargo` is
missing, the build stops with an error saying so.

Run the unit tests (parsers, response math):

```bash
xcodebuild test -project EQTuneBar.xcodeproj -scheme EQTuneBar -destination 'platform=macOS,arch=arm64' -derivedDataPath build
```

## Installing the eqtune engine

Nothing to do by hand: Oomph ships eqtune inside the app. On first launch, if the engine isn't
installed, Oomph shows a setup screen; **Install engine** runs `eqtune install` (which copies
the engine to `~/Library/Application Support/eqtune` and registers a LaunchAgent) and then
`eqtune on`. macOS then asks once for audio-capture permission. eqtune doesn't answer
anything until you respond, so the setup window waits and closes itself once the EQ is on.

On every launch Oomph compares the installed engine's version with the bundled one and quietly
re-runs `eqtune install` if they differ (for example after updating Oomph). Moving Oomph.app
doesn't affect the engine, because the daemon runs from its own copy.

**Settings → Uninstall engine** runs `eqtune uninstall`. It stops the daemon and removes it;
eqtune's presets stay in `~/Library/Application Support/eqtune`.

To use eqtune from Terminal as well, install the CLI the usual way:

```bash
cargo install --locked eqtune && eqtune install
```

Oomph picks its binary in this order: the bundled engine, the path set in Settings, then
`~/.cargo/bin/eqtune` (then `/usr/local/bin` and `/opt/homebrew/bin`).

## How it works

- `EQTuneBar/Core/ProcessEqtuneClient.swift` runs the CLI off the main thread with stdin at
  `/dev/null` and a 5-second timeout, and logs each command with its exit code
  (`log stream --predicate 'subsystem == "com.dipu.eqtunebar"'`). Everything goes through the
  `EqtuneClient` protocol, so a Unix-socket client could replace it later.
- `EqtuneStore` keeps only the latest `status`, preset list and (while the editor is open) the
  active preset. It polls every 2 seconds while the menu or a window is open and not at all
  otherwise. CLI calls run one at a time.
- The parsers are written against real eqtune 0.7.1 output: see
  [Docs/cli-samples.md](Docs/cli-samples.md).

## Known limitations

- **eqtune's output is not a stable API.** Oomph parses the human-readable text of `status`,
  `ls`, `preset-show` and `preset-export`, pinned to eqtune 0.7.x. If a future eqtune changes the
  format, Oomph shows "couldn't read eqtune's output" with the raw text instead of guessing.
- **Discarding unsaved edits answers eqtune's prompt.** `eqtune off` has no flag for it, and
  switching presets keeps edits, so **Discard** runs `eqtune off` with `d` typed on its stdin.
  That is the only command not run with stdin at `/dev/null`. The EQ is already off by the time
  the question appears, so **Cancel** leaves it off with the edits still unsaved.
- **The band editor reads `preset-export`, not `preset-show`.** `preset-show` rounds (10 Hz
  steps above 1 kHz, 0.1 dB, 0.01 Q), while eqtune matches a band only within 0.5 Hz, so editing
  from it could change or duplicate bands. The editor shows exact values from a temporary
  export, changes only the field you touched, and won't move a band onto another band's
  frequency (eqtune would merge them). The `preset-show` parser is kept and tested as
  specified, but the app doesn't need it.
- **eqtune never clears `last error`.** Oomph shows the yellow warning and the red dot only while
  the EQ should be running and isn't (auto-off pauses don't count), not for an old error.
- **eqtune handles one request at a time** and can be busy for several seconds while it starts
  its audio engine. A command can then report "eqtune was busy"; the next refresh shows what
  actually happened.
- **macOS asks for audio-capture permission again after an engine update.** `eqtune install`
  signs the daemon ad hoc, so each new engine binary looks like a new app to macOS.
- **The binary path in Settings is a fallback.** It's used only if the bundled engine is
  missing.
- **Untested: a downloaded copy.** `eqtune install` copies the engine with its file attributes
  and signs the copy ad hoc. If Oomph is downloaded (and quarantined), Gatekeeper may refuse to
  start that copy. Check this before distributing builds.
- **The menu bar icon updates while Oomph is polling.** Changes made from Terminal while the
  menu is closed show up the next time you open it.
- **Not in v1:** global hotkeys, AutoEQ/headphone profile import, per-app or per-device EQ, a
  direct socket connection, App Store distribution, Intel builds.

## Licenses

Oomph is released under the [MIT License](LICENSE).

eqtune is © its authors and licensed under MIT or Apache-2.0. Oomph doesn't copy its code: it
builds it from the `Vendor/eqtune` git submodule, and the app bundle includes both license
texts in `Contents/Resources/Licenses`.
