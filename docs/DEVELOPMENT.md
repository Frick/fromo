# Headless engine

The hidden headless command executes the core engine, publishes state and logs,
serves the Unix socket and prints UI effects as JSON lines. It requires both XDG
roots inside the system temporary directory.

```sh
TEST_ROOT=$(mktemp -d)
export XDG_CONFIG_HOME="$TEST_ROOT/config" XDG_STATE_HOME="$TEST_ROOT/state"
swift run fromo engine --headless
```

In another terminal with the same two XDG variables, use `fromo start`,
`fromo status --json`, `fromo break`, `fromo end-break` and
`fromo answer --did --no-start`. Use `Ctrl+C` to stop the headless process.
Only valid phase transitions are accepted. A work countdown must expire before
`fromo break` becomes available.

Automated checks:

```sh
swift build
swift test
python3 scripts/test-ipc.py
python3 scripts/test-stats.py
shellcheck contrib/sketchybar/fromo.sh
sh scripts/test-sketchybar.sh
```

The integration harness injects a fixed epoch into the headless shell and prepares
synthetic persisted states to exercise expiry without sleeping. SketchyBar tests
stub its commands and clock and compare the exact argument list for every phase.
`fromo status --debug` queries the engine's cached probes and nag policy;
`--debug --json` returns the same details as JSON.

# Stats

`fromo stats` reads CSV files directly, defaulting to Monday through today.
`--today`, `--week`, `--month` and inclusive `--from YYYY-MM-DD --to YYYY-MM-DD`
select the period. Add `--json` for structured output. No running app is needed.
The current config's daily goal applies across the entire report period.
Missing days count as zero; malformed/unsupported rows produce one stderr warning.

Stats tests use synthetic CSV fixtures in temporary XDG directories. Core date
range tests inject the clock/calendar; CLI fixture checks select explicit dates.
