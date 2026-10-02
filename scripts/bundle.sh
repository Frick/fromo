#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
version=$(git describe --tags --always)
short_version=$(printf '%s' "$version" | sed -n 's/^v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)$/\1/p')
short_version=${short_version:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}
bundle=Fromo.app
archive="Fromo-${version}.zip"
build_dir=$(swift build -c release --show-bin-path)

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Helpers" "$bundle/Contents/Resources"
cp "$build_dir/FromoApp" "$bundle/Contents/MacOS/FromoApp"
cp "$build_dir/fromo" "$bundle/Contents/Helpers/fromo"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
plutil -replace FromoBuildVersion -string "$version" "$bundle/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$short_version" "$bundle/Contents/Info.plist"
codesign --force --sign - "$bundle/Contents/Helpers/fromo"
codesign --force --sign - "$bundle"
ditto -c -k --keepParent "$bundle" "$archive"
printf 'Created %s\n' "$archive"
