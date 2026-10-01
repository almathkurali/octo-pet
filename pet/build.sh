#!/bin/sh
# Builds Octo.app into ~/.claude/octo-pet. The mod runs this once, and again
# whenever Octo.swift is newer than the binary. Needs the Xcode Command Line
# Tools (xcode-select --install) for swiftc; nothing else.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
OUT="$HOME/.claude/octo-pet"
APP="$OUT/Octo.app"
mkdir -p "$APP/Contents/MacOS" "$OUT/sessions" "$OUT/cmd"

command -v swiftc >/dev/null || { echo "swiftc not found: run xcode-select --install" >&2; exit 1; }
swiftc -O -swift-version 5 -framework AppKit -framework AVFoundation -o "$APP/Contents/MacOS/Octo" "$HERE/Octo.swift" 2>&1 | grep -v "warning:\|^\s*[0-9]* |\|^\s*|\|^\s*\^\|note:\|^$" || true
[ -x "$APP/Contents/MacOS/Octo" ] || { echo "swiftc produced no binary" >&2; exit 1; }

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Octo</string>
  <key>CFBundleIdentifier</key><string>dev.octo-pet.Octo</string>
  <key>CFBundleExecutable</key><string>Octo</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
EOF

# The easter egg's face: a public avatar, fetched once; without it the egg shows Clawd.
[ -f "$OUT/egg.png" ] || curl -fsSL -m 10 "https://github.com/bcherny.png?size=400" -o "$OUT/egg.png" 2>/dev/null || true

# A pet already running is the previous build: it leaves, the mod relaunches it.
[ -f "$OUT/pet.pid" ] && kill "$(cat "$OUT/pet.pid")" 2>/dev/null || true
rm -f "$OUT/pet.pid"
echo "built $APP"
