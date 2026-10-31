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
- **A preset per output device**, from the menu or Settings › Devices. An output can also
  be set to **No EQ**, which turns the EQ off while it plays and back on for the next
  output, and **Other outputs** sets one preset for every output without its own.
- **Headroom check** that warns when boosts would distort loud audio, with a one-click fix.
- **Headphone correction import** from AutoEq / Equalizer APO parametric EQ files.
- **Find Your Headphones**: search AutoEq's 8,850 measured corrections for headphones and
  earbuds from the equalizer's **+** menu and add one as a preset, optionally for the
  current output. The list is downloaded at most once a day and kept for offline use.
- **Undo and redo** for band and preamp changes.
- **Global shortcuts** in Settings › Shortcuts: turn the EQ on or off and step to the next
  or previous preset from any app, with a brief on-screen confirmation.
- **Reset**: put a preset back to its original state from the equalizer, the menu bar or its
  right-click menu: a Sound Library or eqtune preset to the tuning it shipped with, one of
  your own to how you last saved it.
- **Built-in presets stay as they shipped.** Saving changes to one of eqtune's or the Sound
  Library's presets asks for a name and saves them as a new preset, “My Bass Boost”, which keeps
  its icon and says which built-in it came from. Saving everything at once (when turning the
  EQ off, or before renaming or deleting) does the same, and says so.
- **Preset names in your own words**, like “Movie Night”: eqtune gets a name made from them,
  and Oomph shows yours. Imported headphone corrections keep their model's name.
- **Preset management**: new, duplicate, rename, delete, export, import, and reset eqtune's
  shipped presets.
- Save all or discard all unsaved edits before preset changes eqtune would otherwise refuse.
- Settings tabs for General, Devices, Engine and About, and a redesigned welcome screen.
- Oomph shows in the Dock and ⌘-Tab while one of its windows is open.
- **Downloads**: every version is published on GitHub Releases as a DMG signed with a
  Developer ID and notarized by Apple. A downloaded copy installs the engine without the
  download's quarantine flag, so macOS lets the engine start.
- Contributor docs, issue and pull request templates, and CI.

### Changed

- The Xcode project, folders and scheme are now named Oomph (previously EQTuneBar).
- eqtune's own presets show as Bright, Mellow and Pro.
- Naming a preset uses one dialog everywhere, which says what's wrong with a name (one that's
  taken, say) and asks again, instead of only dimming its button.
- Turning the EQ off with unsaved edits now offers Save, Discard or Cancel.
- The app uses the icon's coral as its accent color.
- The equalizer animates its changes: switching presets morphs the curve into the new one,
  and selecting a band, changing the scale or showing a banner no longer jumps the layout.
  Every preset in the sidebar says what it sounds like, eqtune's own included, and Sound
  Library presets keep their description after they're added.
- The equalizer's toolbar buttons have more room around their titles, and Hold to Compare
  is a button like them rather than a box inside one.

### Fixed

- The sidebar no longer jumps back to the previous preset while eqtune switches, and quick
  clicks or arrow keys go straight to the last preset picked.
- The EQ switch in the menu bar and the equalizer, and the switches in Settings › Engine, no
  longer flip back for a moment while eqtune applies the change.
- Clicking a Sound Library preset twice no longer tries to add it twice.
- A dragged point stays under the pointer, and grabbing it again before eqtune has answered
  carries on from where it is instead of snapping back.
- The Gain, Width and Preamp sliders keep the value they're let go at, and typed values are
  sent as typed: on Return, on Tab or when clicking away.
- Changes in quick succession all arrive, in order: arrow keys at any pace, a step back, a
  typed gain right after a typed frequency, Delete while a band is still moving. The band
  stays selected throughout.
- The Delete key removes the selected band.
- Band chips, the graph's readout and the headroom reading keep their width as values change,
  so nothing beside them shifts; the menu's distortion warning sits on its curve instead of
  resizing the menu, and the menu opens on the real curve rather than a flat one.
- Toolbar and menu controls no longer blink after every edit, and ⌘S works right after a band
  is dragged, nudged or typed, sending a value still being typed first.
- The automatic ±12/±24 dB scale only widens while a preset is open, so the graph no longer
  flips back and forth after a release, and deep cuts now count.
- Saving, Undo and Redo, the preamp, Auto, Bass and Treble, and adding a band no longer act on
  another preset when a switch to it is under way.
- An error shows in the line under the graph instead of resizing it, and stays put on a retry.
  One slow answer from eqtune no longer blanks the window.
- Hold to Compare switches faster, Reset on a Sound Library preset that isn't in use goes back
  to the preset in use when it's done, a new preset can't take a Sound Library preset's name, and
  Launch at Login updates on returning from System Settings.

## [1.0] - 2026-10-29

### Added

- Menu bar app for eqtune: EQ switch, output device, preset list, bypass and preamp.
- Band editor with a frequency-response chart; Settings window; first-run engine install;
  version check of the installed engine at launch.
- eqtune v0.7.1 bundled as a submodule, built by a cargo build phase.

[Unreleased]: https://github.com/immdipu/oomph/compare/1470f62...HEAD
[1.0]: https://github.com/immdipu/oomph/commit/1470f62
