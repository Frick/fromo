# M0 — Scaffold (`v0.0.1`)

1. Open the milestone CI run and confirm both `linux` and `macos` jobs are green. Expected: the `Fromo-macos` artifact contains one `Fromo-*.zip` archive.
2. On the Mac, install the branch artifact with `sh scripts/install.sh --run RUN_ID` (replace `RUN_ID` with that CI run's ID; `gh` authentication is required). Expected: the script reports the installed build version and opens Fromo without a macOS security block.
3. Look in the macOS menu bar for the timer icon, then click it. Expected: a `Quit Fromo` menu item appears.
4. Select `Quit Fromo`. Expected: the timer icon disappears and the app quits.
5. Run `~/.local/bin/fromo --version`. Expected: it prints `0.0.1` and exits successfully.
6. Once the `v0.0.1` release is published, run `sh scripts/install.sh` to verify the release-download path. Expected: it installs and opens the same app; the CLI still prints `0.0.1`.
