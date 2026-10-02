#!/bin/sh
# Requires jq and a Nerd Font for the Material Design icons.
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$PATH"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/fromo/state.json"

# Catppuccin Mocha; replace these values to match the owner's colors.sh.
RED=0xfff38ba8 GREEN=0xffa6e3a1 TEAL=0xff94e2d5 PEACH=0xfffab387
YELLOW=0xfff9e2af OVERLAY1=0xff7f849c SUBTEXT0=0xffa6adc8
ICON_COLOR=0xff121219 LABEL_COLOR=0xffECEFF4 LABEL_BACKGROUND=0xff3C3E4F
TIMER='󰔛' COFFEE='󰅶' PAUSE='󰏤' FOOD='󰔉' ALERT='󰀪'

if [ "${SENDER:-}" = "mouse.clicked" ]; then
    if [ "${BUTTON:-}" = "right" ]; then fromo toggle; else fromo next; fi
    exit "$?"
fi

hide() { sketchybar --set "$NAME" drawing=off; exit 0; }
[ -r "$STATE" ] || hide

# One jq invocation. A unit separator preserves empty fields; tab IFS would collapse them.
fields=$(jq -er '
    select(.pid | type == "number" and . > 0 and floor == .) |
    [.phase,.pid,.break_kind,.ends_at,.ended_at,.remaining,
     (.task // "" | gsub("[\r\n\u001f]"; " ")),.lunch.ends_at,.in_meeting] |
    map(. // "" | tostring) | join("\u001f")' "$STATE" 2>/dev/null) || hide
US=$(printf '\037')
IFS="$US" read -r phase pid kind ends_at ended_at remaining task lunch_ends in_meeting <<EOF
$fields
EOF
case "$pid" in ''|*[!0-9]*) hide ;; esac
[ "$phase" = "stopped" ] && hide
kill -0 "$pid" 2>/dev/null || hide

now=$(date +%s)
number() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }
fmt() { s=$1; [ "$s" -lt 0 ] && s=0; printf '%02d:%02d' "$((s / 60))" "$((s % 60))"; }
time=""
case "$phase" in
    ready) color=$SUBTEXT0; text=Ready; icon=$TIMER ;;
    work) number "$ends_at" || hide
        color=$RED; text=Working; icon=$TIMER; time=$(fmt "$((ends_at - now))") ;;
    work_done) number "$ended_at" || hide
        color=$PEACH; text='Break time'; icon=$ALERT; time="+$(fmt "$((now - ended_at))")" ;;
    break) number "$ends_at" || hide
        color=$GREEN; [ "$kind" = "long" ] && color=$TEAL
        text=${task:-Break}; icon=$COFFEE; time=$(fmt "$((ends_at - now))") ;;
    break_done) number "$ended_at" || hide
        color=$PEACH; icon=$ALERT
        if [ -n "$task" ]; then text="Did $task?"; else text='Break over'; fi
        time="+$(fmt "$((now - ended_at))")" ;;
    paused) number "$remaining" || hide
        color=$OVERLAY1; text=Paused; icon=$PAUSE; time=$(fmt "$remaining") ;;
    lunch) number "$lunch_ends" || hide
        color=$YELLOW; text=Lunch; icon=$FOOD; time=$(fmt "$((lunch_ends - now))") ;;
    *) hide ;;
esac

if [ "$in_meeting" = "true" ]; then label=$time
elif [ -n "$time" ]; then label="$text ~ $time"
else label=$text
fi
label_drawing=on
[ -n "$label" ] || label_drawing=off
sketchybar --set "$NAME" drawing=on "label=$label" "icon=$icon" \
    "icon.color=$ICON_COLOR" "label.color=$LABEL_COLOR" background.drawing=off \
    icon.background.drawing=on "icon.background.color=$color" \
    "label.background.drawing=$label_drawing" "label.background.color=$LABEL_BACKGROUND" "label.drawing=$label_drawing"
