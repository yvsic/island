#!/bin/zsh
# Downloads the pinned xray-core build for this Mac, checks its SHA-256
# against the release's .dgst file, and puts the binary at Resources/xray/xray.
# build.sh bundles it into Island.app and signs it with the app's identity.
# Usage: tools/fetch-xray.sh [version]   (default: the pinned one below)
set -euo pipefail
here=${0:A:h:h}
version=${1:-v26.11.9}
case $(uname -m) in
  arm64) asset=Xray-macos-arm64-v8a.zip ;;
  x86_64) asset=Xray-macos-64.zip ;;
  *) echo "unsupported CPU"; exit 1 ;;
esac
base="https://github.com/XTLS/Xray-core/releases/download/$version"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
echo "downloading $asset $version"
curl -fsSL --retry 5 -C - -o "$work/$asset" "$base/$asset"
curl -fsSL --retry 5 -o "$work/$asset.dgst" "$base/$asset.dgst"
want=$(grep -i 'SHA2-256' "$work/$asset.dgst" | awk -F'= ' '{print $2}' | tr -d '[:space:]')
got=$(shasum -a 256 "$work/$asset" | awk '{print $1}')
[[ -n "$want" && "$want" == "$got" ]] || { echo "checksum mismatch: want $want got $got"; exit 1; }
mkdir -p "$work/out"
unzip -q -o "$work/$asset" xray -d "$work/out"
mkdir -p "$here/Resources/xray"
install -m 755 "$work/out/xray" "$here/Resources/xray/xray"
echo "$version $got" > "$here/Resources/xray/VERSION"
echo "ok: $("$here/Resources/xray/xray" version | head -1)"
