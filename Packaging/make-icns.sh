#!/usr/bin/env bash
# Builds Packaging/AppIcon.icns from the icon renderer.
#
#   Packaging/make-icns.sh [source.png]
#
# Without an argument it renders a fresh 1024x1024 PNG with make-icon.swift first.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
iconset="$here/AppIcon.iconset"
icns="$here/AppIcon.icns"
master="${1:-$here/AppIcon-1024.png}"

if [[ $# -eq 0 ]]; then
    echo "==> Rendering 1024x1024 master icon"
    swift "$here/make-icon.swift" "$master"
fi
[[ -f "$master" ]] || { echo "error: $master not found" >&2; exit 1; }

echo "==> Creating iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

echo "==> Converting to icns"
iconutil -c icns "$iconset" -o "$icns"
rm -rf "$iconset"
echo "    $icns"
