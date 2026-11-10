#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
BUILD_ARGS=(-c release --scratch-path "${NOVA_SCRATCH_PATH:-$HOME/Library/Caches/NovaContextChecks/recheck-20261029}")
if [ "${NOVA_UNIVERSAL:-0}" = "1" ]; then
  BUILD_ARGS+=(--arch arm64 --arch x86_64 --scratch-path .build-universal)
fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
APP="${NOVA_OUTPUT_DIR:-$(pwd)/dist}/归记.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
ICONSET="$(pwd)/dist/InkPen.iconset"
mkdir -p "$ICONSET"
LOGO="$(pwd)/Sources/NovaContext/BrandAssets.xcassets/BrandLogo.imageset/InkPen.png"
# Render a legacy macOS ICNS silhouette, retaining the approved ink artwork.
swift scripts/render-app-icon.swift "$LOGO" "$(pwd)/dist/AppIcon-1024.png"
LOGO="$(pwd)/dist/AppIcon-1024.png"
# Create the standard macOS icon resolutions.
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$LOGO" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  sips -z "$retina_size" "$retina_size" "$LOGO" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN_DIR/NovaContext" "$APP/Contents/MacOS/NovaContext"
for bundle in "$BIN_DIR"/*.bundle; do
  if [ -d "$bundle" ]; then ditto "$bundle" "$APP/Contents/Resources/$(basename "$bundle")"; fi
done
cp scripts/nova-agent.py "$APP/Contents/Resources/nova-agent.py"
cp ../LICENSE "$APP/Contents/Resources/MiaoYan-LICENSE.txt"
cp Vendor/ZIPFoundation/LICENSE "$APP/Contents/Resources/ZIPFoundation-LICENSE.txt"
cp Vendor/swift-cmark-gfm/Sources/CMarkGFM/COPYING "$APP/Contents/Resources/cmark-LICENSE.txt"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>NovaContext</string>
<key>CFBundleIdentifier</key><string>com.novatechai.context.demo</string>
<key>CFBundleName</key><string>归记</string>
<key>CFBundleDisplayName</key><string>归记</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>zh-Hans</string><string>zh-Hant</string><string>en</string><string>es</string><string>tr</string><string>ja</string></array>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>21</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHumanReadableCopyright</key><string>NovaTech AI Limited. Includes MiaoYanCore © Tw93 under MIT.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Merge Packaging/DocumentTypes.plist" "$APP/Contents/Info.plist"
python3 - "$APP" <<'PY_CLEAN'
from pathlib import Path
import sys
for file in Path(sys.argv[1]).rglob("._*"):
    if file.is_file(): file.unlink()
PY_CLEAN
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$APP"
