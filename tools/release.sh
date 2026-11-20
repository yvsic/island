#!/bin/zsh
# Sends out an update: builds, packs and signs the dmg, writes the version note,
# and uploads both to the update site. Everyone running Island picks it up within hours.
# One-time setup: `npx -y netlify-cli login` (a browser window opens).
# Usage: tools/release.sh [--no-deploy]
set -euo pipefail
here=${0:A:h:h}
site_id="1f56e1ae-173c-46a4-80e6-4b298369b97c"
base="https://island-notch-updates-390.netlify.app"

"$here/tools/make_dmg.sh" >/dev/null
app="$HOME/Applications/Island.app"
build=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$app/Contents/Info.plist")
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$app/Contents/Info.plist")

out="$here/site"
mkdir -p "$out"
setopt nullglob; rm -f "$out"/Island-*.dmg
cp "$here/dist/Island.dmg" "$out/Island-$build.dmg"
sha=$(shasum -a 256 "$out/Island-$build.dmg" | cut -d' ' -f1)
sig=$(swift "$here/tools/update_tool.swift" sign "$out/Island-$build.dmg" | tail -1)
cat > "$out/latest.json" <<J
{"build": $build, "version": "$version", "url": "$base/Island-$build.dmg", "sha256": "$sha", "signature": "$sig"}
J
cp "$here/dist/Island.dmg" "$out/Island.dmg"   # a fixed link for first-time installs
cat > "$out/_headers" <<'H'
/latest.json
  Cache-Control: no-cache
H
echo "built update $build"
[[ " $* " == *" --no-deploy "* ]] && exit 0
npx -y netlify-cli deploy --prod --dir "$out" --site "$site_id"
echo "sent: $base/latest.json"
