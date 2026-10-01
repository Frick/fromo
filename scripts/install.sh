#!/bin/sh
set -eu

repo=Frick/fromo
run_id=
if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 2 ] || [ "$1" != "--run" ]; then
        printf 'Usage: %s [--run RUN_ID]\n' "$0" >&2
        exit 64
    fi
    run_id=$2
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

if [ -n "$run_id" ]; then
    command -v gh >/dev/null || { printf 'gh is required for branch builds\n' >&2; exit 1; }
    gh run download "$run_id" --repo "$repo" --name Fromo-macos --dir "$tmp"
    set -- "$tmp"/Fromo-*.zip
    [ -f "$1" ] || { printf 'No Fromo archive in CI artifact\n' >&2; exit 1; }
    archive=$1
else
    archive="$tmp/Fromo.zip"
    curl -fL "https://github.com/$repo/releases/latest/download/Fromo.zip" -o "$archive"
fi

ditto -x -k "$archive" "$tmp"
[ -x "$tmp/Fromo.app/Contents/MacOS/FromoApp" ] || {
    printf 'Invalid Fromo bundle\n' >&2
    exit 1
}

destination="$HOME/Applications/Fromo.app"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"
if [ -d "$destination" ]; then
    pkill -x FromoApp 2>/dev/null || true
    count=0
    while pgrep -x FromoApp >/dev/null && [ "$count" -lt 30 ]; do
        sleep 1
        count=$((count + 1))
    done
    if pgrep -x FromoApp >/dev/null; then
        printf 'Fromo is still running; quit it before installing\n' >&2
        exit 1
    fi
    rm -rf "$destination"
fi
mv "$tmp/Fromo.app" "$destination"
xattr -dr com.apple.quarantine "$destination" 2>/dev/null || true
ln -sfn "$destination/Contents/Helpers/fromo" "$HOME/.local/bin/fromo"
open "$destination"
version=$(/usr/libexec/PlistBuddy -c 'Print :FromoBuildVersion' "$destination/Contents/Info.plist")
printf 'Installed Fromo %s\n' "$version"
