#!/bin/zsh
# Builds a release Island and packs it into dist/Island.dmg for other people.
# There is no Developer ID certificate here, so the app is signed ad hoc: it runs
# on other Macs, but the first launch needs right-click > Open (see the note inside).
set -euo pipefail
here=${0:A:h:h}
name="Island"
"$here/build.sh" >/dev/null
src="$HOME/Applications/$name.app"
[[ -d "$src" ]] || { echo "no built app"; exit 1; }

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto "$src" "$stage/$name.app"
# A signature from this Mac's own certificate means nothing elsewhere: sign ad hoc.
codesign --force --options runtime --entitlements "$here/Island.entitlements" --sign - "$stage/$name.app" 2>&1 | grep -v "replacing existing signature" || true
codesign --verify --deep --strict "$stage/$name.app"
ln -s /Applications "$stage/Applications"
cat > "$stage/Read me first.txt" <<'T'
Install: drag Island onto Applications, then open it from there.

Island is not notarized by Apple, so macOS will say it can't verify it the first time.
Open it with right-click > Open > Open. If macOS only offers "Move to Bin", go to
System Settings > Privacy & Security, scroll down, and press "Open Anyway".
Or, in Terminal:  xattr -cr /Applications/Island.app

Island lives in the notch (no menu bar icon). Hover the notch to open it. Right-click it for Quit.
macOS will ask for permissions as features need them (Spotify/Music control, Calendar,
Location, Screen Recording, Microphone). Messages banners need Full Disk Access.
T

mkdir -p "$here/dist"
out="$here/dist/$name.dmg"
rm -f "$out"
hdiutil create -volname "$name" -srcfolder "$stage" -ov -format UDZO -imagekey zlib-level=9 "$out" >/dev/null
echo "$out ($(du -h "$out" | cut -f1))"
