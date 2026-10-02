# Fromo

A native macOS Pomodoro timer with a CLI, optional SketchyBar integration, and a
small twist: every break suggests something to do, and you answer whether you did
it before starting the next work session.

Built for the owner's routine, shared in case it fits yours. The app lives in the
menu bar, uses native controls and notifications, and keeps its data in local
TOML, JSON and CSV files.

## Install

Release builds are **Apple Silicon (arm64)** and require **macOS 14 or later**.
The app is built against the current macOS SDK and verified on macOS 26. SketchyBar
is optional; the native menu and CLI work on their own.

On the Mac:

```sh
installer=$(mktemp)
curl -fsSL https://raw.githubusercontent.com/Frick/fromo/main/scripts/install.sh -o "$installer" &&
  sh "$installer"
rm "$installer"
```

The installer downloads the [latest release](https://github.com/Frick/fromo/releases/latest),
replaces `~/Applications/Fromo.app`, links the bundled CLI at `~/.local/bin/fromo`,
and opens the app. Run it again to update. Builds are ad-hoc signed; the installer
removes the downloaded bundle's quarantine attribute.

Add the CLI directory to your shell's `PATH` if it is not already there:

```sh
export PATH="$HOME/.local/bin:$PATH"
fromo --version
```

Put that `export` in your shell's startup file to keep it across sessions. You can
also invoke `~/.local/bin/fromo` directly.

On first launch, allow notification alerts, then open **Settings…** from the timer
menu or run `fromo settings`. Review the break tasks, work hours and nag settings.
Launch at login is enabled by default; if macOS requires approval, Settings →
General provides a button opening Login Items.

## The loop

1. **Start work.** The default countdown is 25 minutes.
2. **Confirm the break.** At zero, work is counted as completed and the timer waits
   for Start Break. Overtime is shown while it waits.
3. **Take the suggested break.** Short breaks default to 5 minutes; after four
   completed work sessions, the break is 15 minutes. Short and long task lists
   rotate independently.
4. **Answer the prompt.** When the break ends, a floating panel asks what you did.
   Doing the suggestion advances its rotation; choosing an Other answer leaves
   it in place for next time. The panel must be answered before another work
   session can start.

Work and break countdowns never start the next phase by themselves. Answering the
break starts work by default because **Start next work session** is checked; turn
it off to return to ready. Return or Y selects the suggestion, 1–9 selects an Other
answer, and Shift inverts the checkbox for that answer. Escape does not dismiss
the prompt.

You can pause/resume, restart or extend a running countdown. Abandon Session
(`fromo reset`) abandons work; skipping a break means starting it, ending it early
and answering. **Lunch** temporarily suspends the current phase; running work or
break time returns paused. **Not Today** disables nags until local midnight.

Countdowns use stored wall-clock deadlines and survive sleep or app restarts. An
expired countdown enters its waiting phase when the app next runs.

## CLI

Control commands talk to the running app. `status`, `stats` and `config validate`
read files directly and also work when the app is stopped; `status --debug` needs
the running engine.

```sh
fromo start
fromo status
fromo pause
fromo resume

# After work finishes:
fromo break

# When the break is over, or after ending it early:
fromo answer --did
# Or, if you did something else and want to return to ready:
fromo answer Other --no-start
```

Choose one answer for each break. An Other answer must match an item in the
configured Other list; matching is case-insensitive and names with spaces should
be quoted. Commands unavailable in the current phase are rejected with a reason.

| Command | Purpose |
| --- | --- |
| `fromo start` / `fromo break` | Start work / start the waiting break |
| `fromo pause` / `fromo resume` / `fromo toggle` | Freeze or resume a countdown |
| `fromo next` | Start work, start a break, resume, end lunch, or re-show the answer panel, depending on phase |
| `fromo restart` / `fromo extend [MIN]` | Restart the countdown / add minutes (default: 5) |
| `fromo end-break` / `fromo reset` | End a break early / abandon work |
| `fromo answer --did [--no-start]` | Confirm the suggested task |
| `fromo answer OTHER [--no-start]` | Choose a configured Other answer |
| `fromo lunch [MIN]` / `fromo lunch --end` | Start lunch (default: 60 minutes) / end it early |
| `fromo not-today [--off]` | Disable nags until midnight / enable them again |
| `fromo status [--json]` | Show current state |
| `fromo status --debug [--json]` | Show idle/device probes and nag eligibility |
| `fromo config path` / `fromo config validate` | Locate or validate the TOML file |
| `fromo settings` | Open the native settings window |

Every command accepts `--help`. CLI exit codes are 0 for success, 1 for a rejected
command, 2 for an unreachable engine, 3 for invalid config and 64 for usage errors.

### Stats

```sh
fromo stats                 # Monday through today
fromo stats --today
fromo stats --month         # First of this month through today
fromo stats --week --json
fromo stats --from 2026-10-01 --to 2026-10-07
```

Reports include completed/abandoned Pomodoros, completed planned focus time
(including extensions), days meeting the goal, short/long breaks, suggestion
compliance and per-task/Other counts. Custom ranges include both dates; missing
days count as zero. The current daily goal applies to every day in the report.
Malformed or unsupported CSV rows are skipped with one aggregate stderr warning.

## Settings and files

Settings changes apply automatically, with no Save button. You can also edit
`config.toml`: valid changes reload without relaunch, and a running countdown keeps
its deadline. Invalid edits leave the last good config in force and produce a
Config error notification. If config is invalid at startup, the app runs with
defaults and leaves the file intact for repair.

The app writes a complete default config on first launch. Missing keys use
defaults; unknown keys warn. The settings UI rewrites the whole file, so TOML
comments and ordering can be lost.

Some defaults worth knowing:

- Work / short / long break: **25 / 5 / 15 minutes**, long break every **4** completed work sessions.
- Short tasks: **Pushups, Squats, Yoga, Meditate**; long tasks: **Go for Walk, Yoga**.
- Other answers: **Other**. Empty suggestion lists allow breaks without a suggested task.
- Daily goal: **8**; work hours: **Monday–Friday, 09:00–18:00 local time**.
- Nags: **every 10 minutes** while ready, waiting or paused during work hours, suppressed after **5 minutes idle**.
- Meeting detection: **camera on, microphone off**; sounds muted during meetings.

For example, a partial config can change the tasks and disable nags:

```toml
[breaks]
short = ["Stretch", "Walk"]
long = ["Walk"]
other = ["Other", "Errand"]

[nags]
enabled = false
```

Both macOS and Linux use XDG paths, with these defaults:

| File | Default path |
| --- | --- |
| Config | `~/.config/fromo/config.toml` |
| Current state | `~/.local/state/fromo/state.json` |
| Daily logs | `~/.local/state/fromo/log/YYYY-MM-DD.csv` |
| Control socket | `~/.local/state/fromo/fromo.sock` |
| App diagnostics | `~/.local/state/fromo/fromo.log` |

`XDG_CONFIG_HOME` and `XDG_STATE_HOME` override the base directories. Use consistent
values for the app, CLI and SketchyBar plugin. Only the engine writes state and
logs; the CLI reads or sends commands.

### Meeting detection and nags

Device probes read running status, not camera frames or microphone audio. A meeting
ends after 30 quiet seconds. While it is active, nags stop, the answer panel is held
back, sounds are muted by default, and SketchyBar shows time only. Phase-change
notifications still post.

If nags or meeting detection behave unexpectedly, run `fromo status --debug`.
Virtual devices or an always-on microphone can report permanently in use. Check
the raw microphone result with no call active before enabling microphone detection;
it is off by default for this reason. After idle/meeting suppression ends, a full
nag interval is granted.

## SketchyBar

The optional [SketchyBar plugin](contrib/sketchybar/README.md) needs `jq`, a Nerd Font
for its icons, and `fromo` on `PATH`. Copy the plugin and use the item snippet in
that guide. It reads `state.json` and computes time each second; the app sends
transition triggers.

Left click runs `fromo next`; right click runs `fromo toggle`. Phase colors fill the
icon background, with dark icons and light text on connected dark label segments.
Use a monospaced label font so ticking seconds do not shift neighboring items.

If SketchyBar is outside `/opt/homebrew/bin/sketchybar` or
`/usr/local/bin/sketchybar`, set its absolute binary path in Settings → SketchyBar.
The plugin's colors, icons and font setup can be adjusted to match your bar.

## Development

SwiftPM package, no Xcode project:

- `FromoCore`: cross-platform engine, config, storage, IPC, nag policy and stats.
- `FromoCLI`: the `fromo` executable.
- `FromoApp`: the macOS-only AppKit/SwiftUI shell.

Swift 6.x builds and tests the core/CLI on Linux. On macOS, `sh scripts/bundle.sh`
assembles an ad-hoc-signed app from a release build. CI builds both platforms and
publishes the macOS bundle as an artifact and on tagged releases.

See [development and headless-engine instructions](docs/DEVELOPMENT.md) for test
commands and temporary XDG setup, and [manual checks](docs/MANUAL_TESTS.md) for the
native macOS shell. Dependencies are limited to `swift-argument-parser` and `TOMLKit`.

## License

[MIT](LICENSE).
