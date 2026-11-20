#!/bin/zsh
# Builds Island and installs it to ~/Applications/Island.app.
# Usage: ./build.sh [--debug] [--open]
set -euo pipefail
here=${0:A:h}
name="Island"
scratch="$HOME/Library/Developer/$name/build"
config=release
[[ " $* " == *" --debug "* ]] && config=debug

identity="${SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 -o '"Apple Development: [^"]*"' | tr -d '"' || true)
fi
# Next, the local "Island Local Signing" certificate: a stable signature, so macOS
# keeps Accessibility and Automation permissions across rebuilds.
if [[ -z "$identity" ]]; then
  identity=$(security find-identity -p codesigning 2>/dev/null | grep -m1 '"Island Local Signing"' | awk '{print $2}' || true)
fi
[[ -n "$identity" ]] || identity=-

swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error|warning:|Build complete" | grep -v "^\[" || true
bin="$scratch/$config/$name"
[[ -x "$bin" ]] || { echo "build failed"; exit 1; }
stale=$(find "$here/Sources" -name '*.swift' -newer "$bin" | head -1)
if [[ -n "$stale" ]]; then
  echo "build failed: binary is older than $stale"
  swift build -c $config --package-path "$here" --scratch-path "$scratch" 2>&1 | grep -E "error" | head -20
  exit 1
fi

app="$HOME/Applications/$name.app"
mkdir -p "$HOME/Applications"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin" "$app/Contents/MacOS/$name"
# Strip symbol names and debug info from a release binary: nothing here helps
# anyone except a disassembler. Must happen before signing, since stripping
# after the fact invalidates the signature.
[[ "$config" == "release" ]] && strip -S -x "$app/Contents/MacOS/$name" 2>/dev/null || true
sed -e "s/__BUILD__/$(date +%Y%m%d%H%M)/" "$here/Info.plist.in" > "$app/Contents/Info.plist"
# The icon: Icon/AppIcon.icon -> Resources/Assets.car + AppIcon.icns, rebuilt when it changed.
if [[ -d "$here/Icon/AppIcon.icon" ]]; then
  car="$here/Resources/Assets.car"
  if [[ ! -f "$car" || -n "$(find "$here/Icon/AppIcon.icon" -newer "$car" | head -1)" ]]; then
    "$here/tools/make_icon.sh"
  fi
  cp -X "$car" "$here/Resources/AppIcon.icns" "$app/Contents/Resources/"
fi
# The VPN helper: xray-core, fetched and checksum-checked by tools/fetch-xray.sh.
# Signed on its own first (same identity, hardened runtime), then sealed into
# the app's signature below.
if [[ -x "$here/Resources/xray/xray" ]]; then
  cp "$here/Resources/xray/xray" "$app/Contents/MacOS/xray"
else
  echo "note: no Resources/xray/xray, so the VPN can't connect. Run tools/fetch-xray.sh"
fi
xattr -cr "$app"
[[ -f "$app/Contents/MacOS/xray" ]] && codesign --force --options runtime --sign "$identity" "$app/Contents/MacOS/xray" 2>&1 | grep -v "replacing existing signature" || true
# Hardened runtime: no other program can inject code into Island and borrow its
# Full Disk Access, Accessibility or Automation permissions.
codesign --force --options runtime --entitlements "$here/Island.entitlements" --sign "$identity" "$app" 2>&1 | grep -v "replacing existing signature" || true
echo "installed $app (signed: ${identity})"

if [[ " $* " == *" --open "* ]]; then
  pkill -x "$name" 2>/dev/null || true
  sleep 0.4
  open "$app"
fi
