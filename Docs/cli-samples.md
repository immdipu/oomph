# eqtune CLI samples

Real output from `eqtune 0.7.1` (the version pinned in `Vendor/eqtune`), captured on the
development Mac on 2026-10-29. Oomph's parsers are written against this text, and the
files in `OomphTests/Fixtures/` are the same captures. eqtune's human output has no
stability promise (only `response` has a JSON mode), so re-check this page when the
submodule moves to a new eqtune version.

## `eqtune status`

`OomphTests/Fixtures/status-on.txt`:

```
intent:        on
engine:        running
suspension:    none
preset:        bass
preamp:        -9.10631 dB
bands:         12
limiter:       true
output UID:    BuiltInHeadphoneOutputDevice
output name:   External Headphones
output rate:   48000 Hz
output stream: 48000 Hz, 2 ch, Float32, interleaved
last error:    none
retry:         idle
bypass:        off
dirty presets: none
low power:     off
auto-off LPM:  on
auto-off idle: on
```

One `label: value` line per field, labels padded to 15 columns. Values, from `src/main.rs`:

| Field | Values |
|---|---|
| `intent` | `on` / `off` (what the user asked for) |
| `engine` | `running` / `stopped` (what is actually happening) |
| `suspension` | `none`, `user-off`, `idle`, `low-power`, `starting`, `recovering`, `recovery-exhausted` |
| `preamp` | full float precision with sign: `-9.10631 dB`, `+0 dB` |
| `limiter` | `true` / `false` (a bool, not on/off) |
| `output UID/name/rate/stream` | text, or `(unavailable)` |
| `last error` | `none` or the error text |
| `retry` | `idle`, `scheduled N/6 in Ss`, `exhausted N/6` |
| `dirty presets` | `none` or names joined with `, ` |
| `bypass`, `low power`, `auto-off LPM`, `auto-off idle` | `on` / `off` |

`status-error.txt` and `status-dirty.txt` in the fixtures are written by hand from these
format strings (the machine had no error and no unsaved edits while capturing).

## `eqtune ls` (alias of `eqtune presets`)

```
* bass
  bright
  mellow
  pro
```

The active preset is prefixed with `* `, the others with two spaces. Sorted by name.

## `eqtune preset-show [name]`

```
bass · preamp -9.1 dB
     32 Hz   +3.0 dB  Q1.41
     60 Hz   +2.0 dB  Q1
     64 Hz   +2.0 dB  Q1.41
  low shelf   100 Hz   +5.0 dB  Q0.7
    125 Hz   +1.0 dB  Q1.41
    250 Hz   -2.0 dB  Q1.41
    500 Hz   -3.0 dB  Q1.41
     1 kHz   -4.0 dB  Q1.41
     2 kHz   -7.0 dB  Q1.41
     4 kHz   -1.0 dB  Q1.41
     8 kHz   +2.0 dB  Q1.41
    16 kHz   +2.0 dB  Q1.41
```

Header `name · preamp ±x.x dB`, then one line per band: `  {kind}{freq:>8}  {gain:>8}  Q{q}`
where kind is empty (peaking), `low shelf ` or `high shelf `. A preset without bands prints
`  (no bands — flat)`. Part of `preset-show pro`:

```
pro · preamp +0.0 dB
     20 Hz   +0.0 dB  Q1.41
     25 Hz   +1.0 dB  Q1.41
   31.5 Hz   +2.0 dB  Q1.41
     1 kHz   +0.8 dB  Q1.41
  1.25 kHz   +1.0 dB  Q1.41
   1.6 kHz   +0.8 dB  Q1.41
     2 kHz   +0.0 dB  Q1.41
```

**The values are rounded**: frequencies at or above 1 kHz print in kHz with at most two
decimals (10 Hz resolution), gain with one decimal, Q with at most two. eqtune matches a band
for `band`/`band-rm` only within 0.5 Hz, so Oomph's band editor works from `preset-export`
instead and never sends a rounded value back.

## `eqtune preset-export <name> <path>`

The daemon (not the CLI) writes the file, so the path must be absolute. Full precision:

```
name = "bass"
preamp_db = -9.10631

[[bands]]
kind = "peaking"
freq = 32.0
gain_db = 3.0
q = 1.41

[[bands]]
kind = "peaking"
freq = 60.0
gain_db = 2.0
q = 1.0
...
```

## `eqtune response --format json`

31 one-third-octave points; `gain_db` includes the preamp. Oomph's chart computes its own
curve from the band parameters and its tests check it against this output
(`OomphTests/Fixtures/bass-response.json`):

```
{
  "sample_rate_hz": 48000.0,
  "preamp_db": -9.10631,
  "points": [
    {
      "frequency_hz": 20.0,
      "gain_db": -2.6864986
    },
  ...
```

## `eqtune off` with unsaved edits

`off` has no flag to skip its question. The daemon turns the EQ off first, then the CLI asks
(no trailing newline):

```
eqtune off — native Apple audio restored
unsaved tuning changes for preset 'bass'
bass (disabled) · preamp -9.1 dB
  ...
Preserve this tuning? [s]ave by name / [o]verwrite bass / [d]iscard: 
```

When only other presets have edits the question is `Keep those edits? [o]verwrite … / [d]iscard: `.
With stdin at EOF (Oomph's `/dev/null`) it prints
`Error: input closed before the prompt was resolved; no save, overwrite, discard, or reset action was taken`
to stderr and exits 1; the EQ stays off and the edits stay unsaved. Answering `d` discards every
unsaved edit. Switching presets (`eqtune p <name>`) does **not** discard: edits stay attached to
their preset.

## Errors and exit codes

| Situation | stderr | exit |
|---|---|---|
| Daemon rejected the request | `error: <message>`, e.g. `error: no such preset: nope` | 1 |
| Daemon not running | `could not reach the eqtune daemon (<os error>). Is it running? Try `eqtune install` then `eqtune on`.` | 1 |
| Daemon busy for more than 5 s (engine starting) | `Resource temporarily unavailable (os error 35)` | 1 |
| Prompt hit EOF, install/uninstall failures | `Error: <message>` | 1 |
| Bad arguments (clap) | `error: …` plus usage | 2 |

Each request waits for the daemon's 100 ms loop: back-to-back `status` calls take about 140 ms.

## `eqtune --help`

```
System-wide audio EQ for macOS

Usage: eqtune <COMMAND>

Commands:
  on             Enable audio processing
  off            Disable audio processing
  status         Show current status
  presets        List available presets (active one marked with *) [aliases: ls]
  preset-show    Show the active preset's curve, or another preset by name
  preset         Switch the active preset [aliases: p]
  preset-save    Save the active tuning under a new, active, or shipped preset name
  preset-clone   Clone an existing preset to a new name and switch to it [aliases: preset-copy]
  preset-rm      Delete one or more presets [aliases: preset-delete]
  preset-rename  Rename a preset
  preset-export  Export a preset to a shareable TOML file
  preset-import  Import a preset TOML file, optionally overriding its name
  band           Set or update a band: <freq_hz> <gain_db> [q]
  low-shelf      Set or update a low shelf: <freq_hz> <gain_db> [q]
  high-shelf     Set or update a high shelf: <freq_hz> <gain_db> [q]
  band-rm        Remove the band at <freq_hz>
  preamp         Set the preamp make-up gain, in dB
  preamp-auto    Set preamp to offset the active filters' maximum boost
  response       Show or export the active frequency response
  bypass         Toggle click-free runtime dry-path bypass (on/off)
  limiter        Toggle the soft limiter (on/off)
  lowpower       Toggle auto-off while macOS Low Power Mode is active (on/off)
  idle           Toggle auto-off while no media is active (on/off)
  reset          Reset all settings, or one shipped preset by name
  install        Install the LaunchAgent and start the daemon
  uninstall      Stop and remove the LaunchAgent
  completions    Generate a shell completion script on stdout
  help           Print this message or the help of the given subcommand(s)

Options:
  -h, --help     Print help
  -V, --version  Print version
```

## `eqtune help band`

```
Set or update a band: <freq_hz> <gain_db> [q]

Usage: eqtune band <FREQ> <GAIN_DB> [Q]

Arguments:
  <FREQ>     
  <GAIN_DB>  
  [Q]        [default: 1]

Options:
  -h, --help  Print help
```
