#!/bin/bash
# Builds, packages, signs and verifies ./dist/Notchmix.app.
#
#   ./build.sh            release build
#   ./build.sh --test     run the unit tests first
#
# Everything this script writes stays inside the project folder: SwiftPM's
# scratch, caches, module cache and temp files all live under ./.build.
# The finished app has no ties to this folder and runs from /Applications
# with this drive ejected.
#
# Signing: uses a Developer ID or Apple Development identity if the keychain
# has one, otherwise ad-hoc. Override with SIGN_IDENTITY="<name or hash>".
set -euo pipefail

source "$(dirname "$0")/Scripts/env.sh"
cd "$ROOT"

APP_NAME="Notchmix"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
ENTITLEMENTS="$ROOT/Resources/$APP_NAME.entitlements"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

step "Toolchain"
echo "Developer dir: ${DEVELOPER_DIR:-$(xcode-select -p)}"
echo "SDK:           $(xcrun --show-sdk-path) ($(xcrun --show-sdk-version))"
swift --version 2>&1 | head -1

if [ "${1:-}" = "--test" ]; then
    step "Unit tests"
    if swift test "${SWIFTPM_FLAGS[@]}" > "$BUILD_DIR/test.log" 2>&1; then
        grep -E "Executed [0-9]+ tests" "$BUILD_DIR/test.log" | tail -1
    else
        grep -E "error:|failed" "$BUILD_DIR/test.log" || true
        fail "tests failed (full log: .build/test.log)"
    fi
fi

# Release configuration: -O with whole-module optimisation (SwiftPM's release
# default). Dead code is stripped at link time, no debug info is emitted, and
# absolute source paths are remapped so nothing in the binary points here.
step "Compile (release)"
swift build "${SWIFTPM_FLAGS[@]}" \
    --configuration release \
    --arch arm64 \
    --product "$APP_NAME" \
    -debug-info-format none \
    -Xswiftc -whole-module-optimization \
    -Xswiftc -file-prefix-map -Xswiftc "$ROOT=." \
    -Xcc "-ffile-prefix-map=$ROOT=." \
    -Xlinker -dead_strip

BINARY="$(swift build "${SWIFTPM_FLAGS[@]}" --configuration release --arch arm64 --show-bin-path)/$APP_NAME"
[ -f "$BINARY" ] || fail "no binary at $BINARY"

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    step "App icon"
    rm -rf "$BUILD_DIR/AppIcon.iconset"
    swift "$ROOT/Scripts/make-icon.swift" "$BUILD_DIR/AppIcon.iconset"
    iconutil -c icns -o "$ROOT/Resources/AppIcon.icns" "$BUILD_DIR/AppIcon.iconset"
fi

step "Assemble $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
EXECUTABLE="$APP/Contents/MacOS/$APP_NAME"

# SwiftPM bakes in run paths for running from the build folder, including the
# toolchain's own directory. Replace them all with the one a bundle should have.
while read -r rpath; do
    [ -n "$rpath" ] && install_name_tool -delete_rpath "$rpath" "$EXECUTABLE"
done < <(otool -l "$EXECUTABLE" | awk '/LC_RPATH/ {getline; getline; print $2}')
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXECUTABLE"

strip -Sx "$EXECUTABLE"

step "Sign"
IDENTITY="${SIGN_IDENTITY:-}"
IDENTITY_KIND="${SIGN_IDENTITY:+custom}"
if [ -z "$IDENTITY" ]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    for kind in "Developer ID Application" "Apple Development" "Mac Developer"; do
        # Each line reads:  1) <40-hex hash> "<kind>: <name> (<team>)"
        IDENTITY="$(printf '%s\n' "$identities" | awk -v kind="\"$kind" 'index($0, kind) { print $2; exit }')"
        if [ -n "$IDENTITY" ]; then
            IDENTITY_KIND="$kind"
            echo "Using a $kind identity ($IDENTITY)"
            break
        fi
    done
fi
if [ -z "$IDENTITY" ]; then
    IDENTITY="-"
    echo "No signing identity in the keychain; signing ad-hoc."
    echo "macOS ties the System Audio Recording permission to this exact build,"
    echo "so it survives relaunches but is asked for again after a rebuild."
fi

SIGN_FLAGS=(--force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY")
# A secure timestamp needs Apple's server and only matters for distribution.
if [ "$IDENTITY_KIND" = "Developer ID Application" ]; then
    SIGN_FLAGS+=(--timestamp)
else
    SIGN_FLAGS+=(--timestamp=none)
fi
codesign "${SIGN_FLAGS[@]}" "$APP"

step "Verify"
status=0

size_kb="$(du -sk "$APP" | awk '{print $1}')"
echo "Size: $(du -sh "$APP" | awk '{print $1}') ($size_kb KB)"
[ "$size_kb" -lt 51200 ] || { echo "FAIL: bundle is over 50 MB"; status=1; }

echo
echo "Linked libraries (otool -L):"
otool -L "$EXECUTABLE" | tail -n +2
if otool -L "$EXECUTABLE" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/System/Library/|/usr/lib/)' >/dev/null; then
    echo "FAIL: links something outside the system"; status=1
fi

echo
echo "Run paths:"
otool -l "$EXECUTABLE" | awk '/LC_RPATH/ {getline; getline; print "  " $2}'

# Nothing in the bundle may mention this folder, the drive, or the toolchain.
leaks="$(grep -rlaE "$ROOT|/Volumes/|${DEVELOPER_DIR:-/nonexistent-developer-dir}" "$APP" || true)"
if [ -n "$leaks" ]; then
    echo "FAIL: build-machine paths found in:"; echo "$leaks"; status=1
else
    echo "No references to the project folder, /Volumes or the toolchain."
fi

echo
if codesign --verify --deep --strict --verbose=2 "$APP"; then
    codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Signature|TeamIdentifier|CodeDirectory)" | sed 's/^/  /'
else
    echo "FAIL: code signature did not verify"; status=1
fi

[ "$status" -eq 0 ] || fail "verification failed"

step "Done"
echo "$APP"
echo
echo "Install with:"
echo "  cp -R ./dist/$APP_NAME.app /Applications/"
