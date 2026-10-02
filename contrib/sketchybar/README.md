# Fromo SketchyBar item

Requires `jq`, the bundled `fromo` CLI on `PATH`, and a Nerd Font for the icons.
Copy `fromo.sh` into the SketchyBar plugin directory, make it executable, then add:

```sh
sketchybar --add event fromo_update \
           --add item fromo right \
           --set fromo update_freq=1 script="$PLUGIN_DIR/fromo.sh" \
               icon.padding_left=6 icon.padding_right=6 \
               label.padding_left=6 label.padding_right=6 \
               icon.background.height=22 icon.background.corner_radius=5 \
               icon.background.padding_left=4 icon.background.padding_right=4 \
               label.background.height=22 label.background.corner_radius=5 \
               label.background.padding_left=4 label.background.padding_right=4 \
           --subscribe fromo fromo_update mouse.clicked
```

The item reads `$XDG_STATE_HOME/fromo/state.json` (default `~/.local/state/fromo/state.json`).
It computes the countdown each second without querying the app. Left click runs
`fromo next`; right click runs `fromo toggle`. The item hides when state is missing,
invalid, stopped, or its PID is dead. During a meeting it shows time only.

The phase color fills the icon's background segment. Icons stay near-black and
labels stay near-white on a dark background segment. The item snippet sets the
connected segment geometry; existing matching item defaults can supply it instead.
Colors and Material Design icons are variables at the top of the script.

The M3 macOS app publishes timer state and sends transition triggers. The hidden
headless engine can also publish state in temporary XDG directories for development.
