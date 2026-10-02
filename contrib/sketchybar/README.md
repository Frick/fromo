# Fromo SketchyBar item

Requires `jq`, the bundled `fromo` CLI on `PATH`, and a Nerd Font for the icons.
Copy `fromo.sh` into the SketchyBar plugin directory, make it executable, then add:

```sh
sketchybar --add event fromo_update \
           --add item fromo right \
           --set fromo update_freq=1 script="$PLUGIN_DIR/fromo.sh" \
           --subscribe fromo fromo_update mouse.clicked
```

The item reads `$XDG_STATE_HOME/fromo/state.json` (default `~/.local/state/fromo/state.json`).
It computes the countdown each second without querying the app. Left click runs
`fromo next`; right click runs `fromo toggle`. The item hides when state is missing,
invalid, stopped, or its PID is dead. During a meeting it shows time only.

The colors and Material Design icons are variables at the top of the script.
Adjust them and the font in the item configuration to match the owner's bar.

M2 ships the plugin and headless engine. The macOS app starts publishing timer
state in M3; its current build still has the scaffold's Quit menu.
