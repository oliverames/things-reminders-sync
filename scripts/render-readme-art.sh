#!/bin/bash
# Renders the README images: the app icon and the menu bar icon in each state.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/docs/images"; TMP="$(mktemp -d)"
mkdir -p "$OUT"
swift "$ROOT/scripts/make-icon.swift" "$TMP/AppIcon.iconset"
cp "$TMP/AppIcon.iconset/icon_256x256.png" "$OUT/icon.png"
# Top-level code is only allowed in a file named main.swift when compiling several files.
cp "$ROOT/scripts/render-readme-art.swift" "$TMP/main.swift"
swiftc -O -o "$TMP/render" "$ROOT/Sources/ThingsRemindersSync/MenuBarIcon.swift" "$TMP/main.swift"
"$TMP/render" "$OUT"
rm -rf "$TMP"
ls -la "$OUT"
