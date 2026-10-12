#!/bin/bash
# Builds "Spider-Man 2 T-Pose Fix.app" (and a zip of it) into ./build.
#
#   ./build-app.sh
#   VERSION=1.2 ./build-app.sh
#   SIGN_IDENTITY="Developer ID Application: ..." NOTARY_PROFILE=notary VERSION=1.2 ./build-app.sh   (release)
#
# NOTARY_PROFILE is a `xcrun notarytool store-credentials` keychain profile: the zip is sent to
# Apple's notary service, and the ticket stapled to the app before it's zipped again.
#
# Apple Silicon only: the bundled shader tools are arm64, and Intel Macs don't have the bug.
#
# The fix's d3d12.dll comes from the rest of the repo (prebuilt/fix, built from shim/fix.c) and
# Microsoft's shader tools from ./build-dxc.sh (in .dxc). No game data goes in the app:
# it builds the fix's shaders from the user's own copy of the game.
set -euo pipefail
cd "$(dirname "$0")"
FIX="$(cd .. && pwd)"

VERSION="${VERSION:-1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

echo "==> Building release binary"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/Spider-Man 2 T-Pose Fix.app"
echo "==> Assembling $APP"
rm -rf build
[[ -x .dxc/bin/dxc ]] || { echo "Run ./build-dxc.sh first (Microsoft's shader tools)." >&2; exit 1; }
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/payload" "$APP/Contents/Helpers" "$APP/Contents/Frameworks" \
    "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/SM2Fix" "$APP/Contents/MacOS/SM2Fix"
cp Resources/Info.plist "$APP/Contents/Info.plist"
plutil -replace CFBundleShortVersionString -string "$VERSION" "$APP/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$BUILD_NUMBER" "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cp "$FIX/prebuilt/fix/d3d12.dll" "$APP/Contents/Resources/payload/"
(cd "$FIX/prebuilt/fix" && shasum -a 256 -c d3d12.dll.sha256)
cp "$FIX/LICENSE" "$APP/Contents/Resources/Licenses/LICENSE.txt"

# Shader tools: executables in Helpers, libraries in Frameworks.
cp .dxc/bin/dxc .dxc/bin/dxa .dxc/bin/dxv "$APP/Contents/Helpers/"
cp .dxc/lib/*.dylib "$APP/Contents/Frameworks/"
cp .dxc/licenses/* "$APP/Contents/Resources/Licenses/"
for tool in dxc dxa dxv; do
    install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/Helpers/$tool" 2>/dev/null || true
done

echo "==> Signing"
SIGN=(--force --sign -)   # ad-hoc
[[ -n "${SIGN_IDENTITY:-}" ]] && SIGN=(--force --options runtime --timestamp --sign "$SIGN_IDENTITY")
for code in "$APP"/Contents/Frameworks/*.dylib "$APP"/Contents/Helpers/*; do
    codesign "${SIGN[@]}" "$code"
done
codesign "${SIGN[@]}" "$APP"
codesign --verify --strict "$APP"

ZIP="build/Spider-Man-2-T-Pose-Fix.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "Notarizing needs SIGN_IDENTITY (a Developer ID Application identity)." >&2; exit 1; }
    echo "==> Notarizing (a few minutes)"
    OUT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
    echo "$OUT"
    grep -q "status: Accepted" <<< "$OUT" || { echo "Notarization failed (see above)." >&2; exit 1; }
    xcrun stapler staple "$APP"
    rm "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
fi
echo "==> Done: $APP ($ZIP)"
