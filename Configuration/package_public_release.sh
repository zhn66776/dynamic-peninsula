#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/public-release"
DERIVED_DATA="$BUILD_DIR/DerivedData"
SOURCE_PACKAGES="$ROOT_DIR/DerivedData/SourcePackages"
APP_PATH="$DERIVED_DATA/Build/Products/Public Release/Dynamic Peninsula.app"
OUTPUT_DIR="$BUILD_DIR"

usage() {
    cat <<'USAGE'
Usage:
  Configuration/package_public_release.sh
      Build Public Release and generate the Universal DMG.

  Configuration/package_public_release.sh --package-only
      Reuse the verified App in build/public-release/DerivedData and generate only the DMG.
USAGE
}

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

PACKAGE_ONLY=0
case "${1:-}" in
    "") ;;
    --package-only)
        PACKAGE_ONLY=1
        shift
        ;;
    --help|-h)
        usage
        exit 0
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac

[[ $# -eq 0 ]] || fail "Unsupported positional arguments."

if [[ "$PACKAGE_ONLY" -eq 0 ]]; then
    /usr/bin/xcodebuild \
        -project "$ROOT_DIR/boringNotch.xcodeproj" \
        -scheme "Public Release" \
        -configuration "Public Release" \
        -destination "generic/platform=macOS" \
        -derivedDataPath "$DERIVED_DATA" \
        -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
        -disableAutomaticPackageResolution \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        build
fi

[[ -d "$APP_PATH" ]] || fail "Public Release App not found: $APP_PATH"
APP_INFO="$APP_PATH/Contents/Info.plist"
APP_BINARY="$APP_PATH/Contents/MacOS/Dynamic Peninsula"
HELPER_BINARY="$APP_PATH/Contents/XPCServices/BoringNotchXPCHelper.xpc/Contents/MacOS/BoringNotchXPCHelper"
MEDIAREMOTE_BINARY="$APP_PATH/Contents/Frameworks/MediaRemoteAdapter.framework/Versions/A/MediaRemoteAdapter"

[[ -f "$APP_INFO" ]] || fail "App is missing Contents/Info.plist."
[[ -x "$APP_BINARY" ]] || fail "App executable is missing or not executable: $APP_BINARY"
[[ -x "$HELPER_BINARY" ]] || fail "XPC helper is missing or not executable: $HELPER_BINARY"
[[ -f "$MEDIAREMOTE_BINARY" ]] || fail "MediaRemoteAdapter is missing: $MEDIAREMOTE_BINARY"

BUNDLE_ID="$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$APP_INFO")"
[[ "$BUNDLE_ID" == "com.haonanzhang.dynamic-peninsula" ]] || fail "Public Release bundle identifier is incorrect: $BUNDLE_ID"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$APP_INFO")"

printf '%s\n' 'Verifying code signatures...'
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"

require_universal() {
    local binary="$1"
    local archs
    archs="$(/usr/bin/lipo -archs "$binary")"
    case " $archs " in
        *' arm64 '*) ;;
        *) fail "Binary is missing the arm64 slice: $binary ($archs)" ;;
    esac
    case " $archs " in
        *' x86_64 '*) ;;
        *) fail "Binary is missing the x86_64 slice: $binary ($archs)" ;;
    esac
    printf '  %s: %s\n' "$binary" "$archs"
}

printf '%s\n' 'Verifying Universal binaries...'
require_universal "$APP_BINARY"
require_universal "$HELPER_BINARY"
require_universal "$MEDIAREMOTE_BINARY"

ENTITLEMENTS="$(/usr/bin/codesign --display --entitlements :- "$APP_PATH" 2>/dev/null)"
STOCK_MARKERS=(
    'StockPortfolioMonitor'
    'PortfolioView'
    'portfolioModuleEnabled'
    'portfolio_tickers_snapshot'
    'portfolio_ticker_notifier'
    'My-Portfolio'
)

printf '%s\n' 'Verifying that Public Release excludes the local stock module...'
for marker in "${STOCK_MARKERS[@]}"; do
    if /usr/bin/strings -a "$APP_BINARY" | /usr/bin/grep -Fi -- "$marker" >/dev/null; then
        fail "App executable still contains a stock-module string: $marker"
    fi
    if /usr/bin/grep -Fi -- "$marker" >/dev/null <<<"$ENTITLEMENTS"; then
        fail "App entitlements still contain a stock-module string: $marker"
    fi
done

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dynamic-peninsula-public.XXXXXX")"
cleanup() {
    /bin/rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

PAYLOAD_DIR="$STAGING_DIR/payload"
mkdir "$PAYLOAD_DIR"

printf '%s\n' 'Preparing DMG contents...'
/usr/bin/ditto "$APP_PATH" "$PAYLOAD_DIR/Dynamic Peninsula.app"
# Remove local build paths recorded in debug symbols, then restore signatures.
STAGED_APP="$PAYLOAD_DIR/Dynamic Peninsula.app"
STAGED_HELPER="$STAGED_APP/Contents/XPCServices/BoringNotchXPCHelper.xpc"
for localization in "$STAGED_APP/Contents/Resources/"*.lproj; do
    [[ -d "$localization" ]] || continue
    case "${localization##*/}" in
        en.lproj|Base.lproj) ;;
        *) /bin/rm -rf "$localization" ;;
    esac
done
/usr/bin/plutil -replace CFBundleDevelopmentRegion -string en "$STAGED_APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleLocalizations -json '["en"]' "$STAGED_APP/Contents/Info.plist"
/usr/bin/plutil -replace CFBundleAllowMixedLocalizations -bool NO "$STAGED_APP/Contents/Info.plist"
printf '%s\n' "$ENTITLEMENTS" > "$STAGING_DIR/app.entitlements"
/usr/bin/codesign --display --entitlements :- "$STAGED_HELPER" > "$STAGING_DIR/helper.entitlements" 2>/dev/null
/usr/bin/xcrun strip -S "$STAGED_APP/Contents/MacOS/Dynamic Peninsula"
/usr/bin/xcrun strip -S "$STAGED_HELPER/Contents/MacOS/BoringNotchXPCHelper"
/usr/bin/codesign --force --sign - --timestamp=none --options runtime --entitlements "$STAGING_DIR/helper.entitlements" "$STAGED_HELPER"
/usr/bin/codesign --force --sign - --timestamp=none --entitlements "$STAGING_DIR/app.entitlements" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"
for binary in "$STAGED_APP/Contents/MacOS/Dynamic Peninsula" "$STAGED_HELPER/Contents/MacOS/BoringNotchXPCHelper"; do
    if /usr/bin/strings -a "$binary" | /usr/bin/grep -F '/Users/' >/dev/null; then
        fail "Release binary still contains an absolute path from the build machine."
    fi
done

/bin/ln -s /Applications "$PAYLOAD_DIR/Applications"
/bin/cp "$ROOT_DIR/LICENSE" "$PAYLOAD_DIR/LICENSE"
/bin/cp "$ROOT_DIR/THIRD_PARTY_LICENSES" "$PAYLOAD_DIR/THIRD_PARTY_LICENSES.md"
/usr/bin/printf '%s\n' \
    'Dynamic Peninsula public release' \
    '' \
    'Install: Drag Dynamic Peninsula.app to the Applications folder, then open it.' \
    'This package supports macOS 26 or later and includes arm64 and x86_64 for Apple silicon and Intel Macs.' \
    '' \
    'macOS security prompt: Open System Settings > Privacy & Security and choose Open Anyway for Dynamic Peninsula.' \
    'Apple guidance: https://support.apple.com/102445' \
    '' \
    'Stock tracking is available in Personal Build. This installer contains Public Release.' \
    'Signing: ad-hoc (unnotarized).' \
    > "$PAYLOAD_DIR/Install.txt"

mkdir -p "$OUTPUT_DIR"
BASE_NAME="Dynamic-Peninsula-${VERSION}-public-macOS26-universal"
OUTPUT_PATH="$OUTPUT_DIR/$BASE_NAME.dmg"
SUFFIX=1
while [[ -e "$OUTPUT_PATH" ]]; do
    OUTPUT_PATH="$OUTPUT_DIR/$BASE_NAME-$SUFFIX.dmg"
    SUFFIX=$((SUFFIX + 1))
done

printf 'Creating: %s\n' "$OUTPUT_PATH"
/usr/bin/hdiutil create \
    -srcfolder "$PAYLOAD_DIR" \
    -volname "Dynamic Peninsula" \
    -format UDZO \
    "$OUTPUT_PATH"

printf 'Completed: %s\n' "$OUTPUT_PATH"
