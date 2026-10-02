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
