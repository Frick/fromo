# M0 — Scaffold (`v0.0.1`)

The owner completed these Mac checks successfully.

1. On the Mac, install the branch artifact with `sh scripts/install.sh --run RUN_ID` (replace `RUN_ID` with that CI run's ID; `gh` authentication is required). Expected: the script reports the installed build version and opens Fromo without a macOS security block.
2. Look in the macOS menu bar for the timer icon, then click it. Expected: a `Quit Fromo` menu item appears.
3. Select `Quit Fromo`. Expected: the timer icon disappears and the app quits.
4. Run `~/.local/bin/fromo --version`. Expected: it prints `0.0.1` and exits successfully.
5. Run `sh scripts/install.sh` to verify the release-download path. Expected: it installs and opens the same app; the CLI still prints `0.0.1`.

# M1 — Core (`v0.1.0`)

No owner action is required. CI, core tests, release assets and public download URLs are verified by the agent.

# M2 — CLI and SketchyBar (`v0.2.0`)

No owner action is required. The agent verifies CLI/socket integration and SketchyBar
rendering against synthetic fixtures on Linux, and verifies macOS compilation and
release downloads through CI and GitHub. The macOS app still has the M0 Quit menu;
the full Mac timer loop is checked in M3.

# M3 — Native app (`v0.3.0`)

The owner verified the native timer loop, notifications, panel, recovery and
SketchyBar integration. Login registration and segmented styling have the targeted
follow-up below.

CI, socket/CLI integration, core models, signing and release downloads are verified
by the agent. These steps check native behavior on the Mac. Settings arrive in M4;
its menu item is disabled in M3. Probe/nag checks arrive in M5.

1. Install with `sh scripts/install.sh`. Allow notification alerts when asked (or enable Fromo alerts in System Settings if permission was previously denied). Expected: Fromo shows a timer menu-bar icon, no Dock icon, and the full timer menu.
2. Quit Fromo. Run `~/.local/bin/fromo config path`, open that TOML file, and temporarily set `work_minutes`, `short_break_minutes`, and `long_break_minutes` to `1`, and `long_break_every` to `2`; keep a copy of the original values. Reopen `~/Applications/Fromo.app`. Expected: the menu is ready and `fromo --version` prints `0.3.0` (use `~/.local/bin/fromo` if it is not on `PATH`).
3. Set up the item using `contrib/sketchybar/README.md`. Expected: SketchyBar displays `Ready`; a left click starts work and shows a decreasing `Working ~ MM:SS` label.
4. Pause from the menu, wait briefly, then resume. Extend the work timer, then restart it. Expected: pausing freezes the displayed time; resume continues; Extend adds the configured minutes; Restart returns to one minute. Invalid menu actions remain visible and disabled.
5. Let work reach zero without acting. Expected: a native “Work session done” notification and Glass sound, `Today: 1 of 8`, and an overtime display. Work remains waiting. The notification offers only `Start Break`.
6. Use the notification's `Start Break` action, then switch to another Space or a full-screen app before the break ends. Expected: the break shows `Pushups`; on expiry a Hero sound and “Break's over” notification appear, and the answer panel floats above the current Space/full-screen app with keyboard focus.
7. Try Escape and closing the answer panel, then choose `Shift+Return` with “Start next work session” checked. Expected: the panel cannot be dismissed without an answer; Shift inverts the checkbox for this answer, so the panel hides and the timer returns to ready. Pushups advances to Squats.
8. Start the next work session using `fromo start`. After it expires, run `fromo break`, `fromo end-break`, then `fromo answer Other --no-start`. Expected: this is the long break with `Go for Walk`; the CLI answer hides the panel and returns to ready. The long suggestion remains `Go for Walk` because Other was chosen.
9. Start work, then run `fromo lunch 1`. Let lunch expire. Expected: a Ping sound and “Lunch is over” notification; the prior work session returns paused with its remaining time. The notification's Continue action resumes it.
10. During a running work countdown, quit and reopen Fromo. Then restart to one minute, put the Mac to sleep until the minute has elapsed, and wake it. Expected: reopening preserves the original deadline; the first tick after wake produces one work-end notification and waits for a break without automatically starting one.
11. Start and end a break so the answer panel is visible. Quit and reopen Fromo, then answer with key `1`. Expected: the pending panel returns on relaunch; key `1` selects Other, hides the panel, and starts work using the checked default. SketchyBar stays synchronized with menu and CLI commands.
12. Choose `Open Log Folder`. Expected: Finder opens the XDG log folder containing the daily CSV; work completions, answers and lunch rows correspond to the loop just performed.
13. Check System Settings → Login Items for Fromo, approve it if requested, then log out and back in. Expected: Fromo launches as a menu-bar agent and restores its timer state. If it does not, report the message in `$XDG_STATE_HOME/fromo/fromo.log` (default `~/.local/state/fromo/fromo.log`).
14. Quit Fromo, restore the original timer values from step 2, and reopen it. Expected: subsequent phases use the original durations.

## M3 follow-up (`v0.3.1`)

1. Install with `sh scripts/install.sh`, with `[general] launch_at_login = true` in the config. Check System Settings → Login Items. Expected: Fromo is registered to open at login, or is listed awaiting approval; approve it if requested. If it remains missing, send the new `Launch at login` lines from `$XDG_STATE_HOME/fromo/fromo.log` (default `~/.local/state/fromo/fromo.log`), which include the requested setting, before/after status and any error domain/code.
2. Log out and back in after registration/approval. Expected: Fromo opens automatically as a menu-bar app and restores its timer state.
3. Replace the SketchyBar plugin with the updated `contrib/sketchybar/fromo.sh` and use the item geometry in its README (or the bar's existing matching defaults), then reload SketchyBar. Expected: a colored icon-background segment with a near-black icon is connected to a dark label segment with near-white text; phase changes recolor the icon background, keeping text/icon colors constant.
