#!/bin/bash
# Builds VRDesktop.app (Apple Silicon) from the Swift package and zips it.
# Usage: mac/scripts/build-app.sh   -> mac/build/VRDesktop.app and mac/build/VRDesktop.zip
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN=$(swift build -c release --arch arm64 --show-bin-path)

APP=build/VRDesktop.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources/web"

cp "$BIN/VRDesktopHost" "$APP/Contents/MacOS/VRDesktop"
cp -R "$BIN/WebRTC.framework" "$APP/Contents/Frameworks/"
cp Web/* "$APP/Contents/Resources/web/"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/VRDesktop" 2>/dev/null || true

VERSION=${VERSION:-0.1.0}
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VR Desktop</string>
  <key>CFBundleDisplayName</key><string>VR Desktop</string>
  <key>CFBundleIdentifier</key><string>com.github.michalmedvecky.vrdesktop</string>
  <key>CFBundleExecutable</key><string>VRDesktop</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSAppTransportSecurity</key><dict><key>NSAllowsLocalNetworking</key><true/></dict>
  <key>NSLocalNetworkUsageDescription</key><string>VR Desktop streamuje okna do brýlí Quest v lokální síti.</string>
  <key>NSScreenCaptureUsageDescription</key><string>VR Desktop zachytává vybraná okna a posílá je do brýlí Quest.</string>
</dict>
</plist>
PLIST

# Code signature. macOS ties the Screen Recording / Accessibility permissions to the signature:
# with an ad-hoc signature (-) every build looks like a new app and the permissions must be
# granted again. With a stable certificate (SIGN_IDENTITY, a self-signed one is enough) they
# survive updates. CI sets SIGN_IDENTITY when the MAC_SIGNING_P12 secret exists.
IDENTITY=${SIGN_IDENTITY:--}
KEYCHAIN_ARGS=()
if [ -n "${SIGN_KEYCHAIN:-}" ]; then KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN"); fi
codesign --force --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]}" "$APP/Contents/Frameworks/WebRTC.framework"
codesign --force --sign "$IDENTITY" "${KEYCHAIN_ARGS[@]}" \
  --identifier com.github.michalmedvecky.vrdesktop "$APP"
codesign --verify --verbose "$APP"
codesign --display --requirements - "$APP" 2>&1 | grep designated || true

(cd build && ditto -c -k --keepParent VRDesktop.app VRDesktop.zip)
echo "Built $(pwd)/build/VRDesktop.app"
