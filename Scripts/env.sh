# Sourced by build.sh and by ad-hoc developer commands.
# Selects a toolchain and pins every cache and temp file inside the project.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"

# Prefer a full Xcode: it carries the newest SDK and XCTest. If the active
# developer directory is only the Command Line Tools, look for one.
if [ -z "${DEVELOPER_DIR:-}" ]; then
    active="$(xcode-select -p 2>/dev/null || true)"
    if [ ! -d "$active/Platforms/MacOSX.platform" ]; then
        # Look in the usual folders and in an Applications folder on any
        # mounted volume first; Spotlight is only a last resort, because its
        # index for an external drive is often missing or still rebuilding.
        # find rather than a glob, so this also works when sourced from zsh,
        # and line-wise so paths with spaces survive.
        while IFS= read -r app; do
            if [ -d "$app/Contents/Developer/Platforms/MacOSX.platform" ]; then
                export DEVELOPER_DIR="$app/Contents/Developer"
                break
            fi
        done <<XCODES
$(find /Applications "$HOME/Applications" -maxdepth 1 -name 'Xcode*.app' 2>/dev/null)
$(find /Volumes -mindepth 3 -maxdepth 3 -path '*/Applications/Xcode*.app' 2>/dev/null)
$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null)
XCODES
    fi
fi

BUILD_DIR="$ROOT/.build"
export TMPDIR="$BUILD_DIR/tmp"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$BUILD_DIR/ModuleCache"
mkdir -p "$TMPDIR"

# Keeps SwiftPM's own caches, config and trust store out of the home folder.
SWIFTPM_FLAGS=(
    --package-path "$ROOT"
    --scratch-path "$BUILD_DIR"
    --cache-path "$BUILD_DIR/swiftpm-cache"
    --config-path "$BUILD_DIR/swiftpm-config"
    --security-path "$BUILD_DIR/swiftpm-security"
)
