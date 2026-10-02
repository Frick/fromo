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

## M3 follow-up (`v0.3.2`)

The owner verified login startup, segmented styling and stable countdown widths.

1. Install with `sh scripts/install.sh`, with `[general] launch_at_login = true` in the config. Check System Settings → Login Items. Expected: Fromo is registered to open at login, or is listed awaiting approval; approve it if requested. If it remains missing, send the new `Launch at login` lines from `$XDG_STATE_HOME/fromo/fromo.log` (default `~/.local/state/fromo/fromo.log`), which include the requested setting, before/after status and any error domain/code.
2. Log out and back in after registration/approval. Expected: Fromo opens automatically as a menu-bar app and restores its timer state.
3. Replace the SketchyBar plugin with the updated `contrib/sketchybar/fromo.sh`; use the geometry and explicit `label.font="MesloLGL Nerd Font:Regular:15.0"` setting in its README, then reload SketchyBar. Observe a running countdown for several seconds. Expected: a colored icon-background segment with a near-black icon is connected to a dark label segment with near-white text; phase changes recolor the icon background, keeping text/icon colors constant. Neighboring items stay stationary as seconds change, as does the native status-item countdown.

# M4 — Settings (`v0.4.0`)

The agent verifies CI, persistence/reload/error policy, signing and release assets.
These checks cover the native controls and filesystem event delivery on the Mac.
Keep a copy of the current config before editing; UI writes rewrite the whole TOML
file and can remove its comments. Nag/probe behavior is checked in M5.

1. Install with `sh scripts/install.sh`, then open `Settings…` from the menu and from `fromo settings`. Expected: one native settings window opens in front, with General, Timer, Breaks, Work Hours, Nags, Sounds and SketchyBar tabs.
2. In General, change the daily goal and toggle launch at login off/on. Commit a Timer duration change and wait about half a second, then inspect the TOML file printed by `fromo config path`. Expected: values are written automatically without Save; the menu's goal updates immediately, login registration follows the toggle, and any required approval has an Open Login Items button.
3. In Breaks, add a synthetic task such as `Stretch`, rename it, drag it to a different position and remove it. Exercise the short, long and other lists. Expected: controls work and the TOML lists preserve the displayed order after closing/reopening settings.
4. Enable a day in Work Hours and choose its start/end times; disable it again. Change a nag interval/message and meeting-detection checkbox in Nags. Expected: TOML contains zero-padded `HH:MM` values or `[]` for a disabled day, and all edited nag/meeting values persist.
5. In Sounds, select a system sound and Preview it; select None; then Choose File… for an audio file and Preview it. Expected: previews play the selected sound, None is silent, and a selected file is stored as an absolute path.
6. In SketchyBar, use the installed binary's absolute path if it is outside the documented auto-search locations. Temporarily run `sketchybar --set fromo update_freq=0 label=stale`, then click Send Test Trigger. Expected: the item redraws immediately from current timer state. Restore per-second updates with `sketchybar --set fromo update_freq=1`.
7. Start work and note `ends_at` from `fromo status --json`. Change its configured duration in settings, then modify the daily goal and a break-list item in an editor that saves by file replacement. Expected: the current deadline stays fixed; settings and menu reflect valid editor changes without relaunch. The next newly started work phase uses the updated duration.
8. With settings open, make the TOML invalid (for example, `work_minutes = -1`) and save it twice. Expected: one Config error notification for that error, an inline settings error, and continued operation with the last good config. The notification's Open Config action opens the file. Repair the file; expected: the error clears and valid values apply.
9. Repeat an invalid file save, quit and reopen Fromo before repairing it. Expected: the app starts with defaults and one Config error notification, leaves the invalid file intact, and still permits settings/editor repair. Restore the original config when finished; expected: the UI and subsequent phases reflect the restored values.

## M4 navigation follow-up (`v0.4.1`)

1. Install with `sh scripts/install.sh` and open Settings. Resize the window down to its minimum width, then click General, Timer, Breaks, Work Hours, Nags, Sounds and SketchyBar in turn. Expected: the window opens wider and all seven native tabs remain directly clickable across the top, including at minimum width; selecting one displays its pane without an overflow menu.
2. Change a setting and switch panes, then return to it. Expected: the edit persists through the pane switch and is written automatically as before.

# M5 — Nags and probes (`v0.5.0`)

The owner verified the M5 checks successfully.

Core eligibility/cooldown/cursor tests, debug IPC, CI, signing and downloads are
verified by the agent. These steps check actual Mac input/device status and native
notifications. Keep the original settings values so they can be restored afterward.

1. Install with `sh scripts/install.sh`. With no call active, run `fromo status --debug`. Expected: idle seconds, camera, microphone, meeting status, work-hours status, eligibility and next-nag epoch are printed; no camera/microphone permission dialog appears. Note whether the external microphone reports in use; leave microphone meeting detection off until this is understood.
2. In Settings, temporarily enable nags, set interval and idle threshold to one minute, and set today's work-hours window to include the current time. Leave the timer ready and keep using the Mac. Expected: a nag appears after a full interval, plays the configured sound, and offers Start Work and Not Today. Start Work starts a countdown; no nags occur while it runs.
3. Pause the countdown and remain active for one interval. Expected: a waiting-message nag offers Continue and Not Today; Continue resumes the paused timer.
4. Return to ready, then leave the Mac untouched for more than one idle-threshold minute and another interval. Expected: no idle-time nags. Resume input and run debug; expected: idle seconds drop and a full interval remains before the next nag.
5. Temporarily set work/short-break durations to one minute. Start a video call with the camera on and run debug after the next five-second probe refresh. Expected: camera/in-meeting are true, nags stop, and SketchyBar shows time only. Start work, let it expire, then run `fromo break` and `fromo end-break` while on the call; expected: the break notification posts, its sound is muted, and the answer panel is held back. Turn the camera off; expected: meeting status stays true for 30 quiet seconds, then the panel appears and a full nag interval is granted. Answer the panel before continuing.
6. In ready/waiting, choose Not Today from a nag or menu. Expected: no further nags, and debug reports Not Today suppression. Turn it off; expected: nags can resume after the normal interval. Enter lunch; expected: no nags while lunch is active.
7. If the no-call microphone result from step 1 was false, temporarily enable microphone meeting detection and use an input-only audio session. Expected: debug reports microphone/in-meeting true and suppresses nags; stopping input grants the same 30-second meeting grace. If it reports permanently in use, retain the default off setting.
8. Restore the original timer/work-hours/nag/meeting settings. Expected: debug and subsequent phases/nags reflect those values without restarting the app.

# M6 — Stats (`v0.6.0`)

Synthetic aggregation, CSV quoting, malformed rows, date ranges, CLI usage/exit codes,
JSON output and operation without an engine are verified by the agent on Linux and
macOS CI. This final check is against the owner's local data; logs stay on the Mac.

1. Install with `sh scripts/install.sh`, then run `fromo stats --week` against a week of accumulated logs. Expected: the report shows completed/abandoned Pomodoros, completed planned focus time including extensions, short/long breaks, suggestion compliance, task/other counts and one completed/goal line per day; missing days show zero.
2. Run `fromo stats --week --json` and compare its totals with the text report and local CSV rows. Expected: the totals agree, and the currently configured daily goal is applied to every day. Text compliance is rounded to whole percent; JSON retains the numeric percentage.
