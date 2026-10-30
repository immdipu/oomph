# Changelog

All notable changes to Oomph are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and Oomph uses
[Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added

- **Equalizer window** with a sidebar of presets and an interactive graph: drag a band's
  point to set frequency and gain, scroll to set its width, double-click to add a band, arrow
  keys to nudge, Delete to remove. Bands are numbered and colored, with a chip strip and an
  inspector for exact values.
- **Frequency guide**: the graph names the sub-bass, bass, low mids, mids, upper mids and
  treble ranges, and each band explains what boosting or cutting it does.
- **Bass and Treble** sliders and a live curve preview in the menu bar.
- **Sound Library**: 14 ready-made tunings (Bass Boost, Treble Reducer, Laptop Speakers,
  Loudness, Vocal Clarity, Dialogue, Electronic, Hip-Hop, Rock, Acoustic, Classical & Jazz,
  Footsteps and more), each with enough headroom not to clip.
- **Hold to Compare** in the menu and the equalizer, for quick A/B listening.
- **A preset per output device**, from the menu or Settings › Devices.
- **Headroom check** that warns when boosts would distort loud audio, with a one-click fix.
- **Headphone correction import** from AutoEq / Equalizer APO parametric EQ files.
- **Undo and redo** for band and preamp changes.
- **Revert and Reset to Original**: go back to a preset's last saved version from the menu
  bar or the equalizer, or restore a Sound Library or eqtune preset to its original tuning.
- **Preset management**: new, duplicate, rename, delete, export, import, and reset eqtune's
  shipped presets.
- Save all or discard all unsaved edits before preset changes eqtune would otherwise refuse.
- Settings tabs for General, Devices, Engine and About, and a redesigned welcome screen.
- Oomph shows in the Dock and ⌘-Tab while one of its windows is open.
- Contributor docs, issue and pull request templates, and CI.

### Changed

- The Xcode project, folders and scheme are now named Oomph (previously EQTuneBar).
- Turning the EQ off with unsaved edits now offers Save, Discard or Cancel.
- The app uses the icon's coral as its accent color.
- The equalizer animates its changes: switching presets morphs the curve into the new one,
  and selecting a band, changing the scale or showing a banner no longer jumps the layout.
  Every preset in the sidebar says what it sounds like, eqtune's own included, and Sound
  Library presets keep their description after they're added.

### Fixed

- The sidebar no longer jumps back to the previous preset while eqtune switches, and quick
  clicks or arrow keys go straight to the last preset picked.
- The EQ switch in the menu bar and the equalizer, and the switches in Settings › Engine, no
  longer flip back for a moment while eqtune applies the change.
- Clicking a Sound Library preset twice no longer tries to add it twice.

## [1.0] - 2026-10-29

### Added

- Menu bar app for eqtune: EQ switch, output device, preset list, bypass and preamp.
- Band editor with a frequency-response chart; Settings window; first-run engine install;
  version check of the installed engine at launch.
- eqtune v0.7.1 bundled as a submodule, built by a cargo build phase.

[Unreleased]: https://github.com/immdipu/oomph/compare/1470f62...HEAD
[1.0]: https://github.com/immdipu/oomph/commit/1470f62
