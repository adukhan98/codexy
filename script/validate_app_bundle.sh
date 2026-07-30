#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexHUD"
BUNDLE_ID="com.adnaankhan.CodexHUD"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="${CODEX_HUD_INSTALL_DIR:-$HOME/Applications}"
APP_BUNDLE="${1:-$INSTALL_DIR/$APP_NAME.app}"
DIST_ARCHIVE="$ROOT_DIR/dist/$APP_NAME.app.zip"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ARCHIVE_VALIDATION_ROOT=""

cleanup_archive_validation() {
    if [[
        -n "$ARCHIVE_VALIDATION_ROOT" &&
        "$(/usr/bin/basename "$ARCHIVE_VALIDATION_ROOT")" == "CodexHUD.archive-validation."* &&
        "$ARCHIVE_VALIDATION_ROOT" == /* &&
        -d "$ARCHIVE_VALIDATION_ROOT"
    ]]; then
        /bin/rm -rf "$ARCHIVE_VALIDATION_ROOT"
    fi
}
trap cleanup_archive_validation EXIT

fail() {
    echo "Bundle validation failed: $1" >&2
    exit 1
}

read_key() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null
}

[[ -d "$APP_BUNDLE" ]] || fail "missing app bundle at $APP_BUNDLE"
[[ -f "$INFO_PLIST" ]] || fail "missing Contents/Info.plist"
[[ -x "$APP_BINARY" ]] || fail "missing executable Contents/MacOS/$APP_NAME"

/usr/bin/plutil -lint "$INFO_PLIST" >/dev/null || fail "Info.plist is malformed"

[[ "$(read_key CFBundleExecutable)" == "$APP_NAME" ]] ||
    fail "CFBundleExecutable must be $APP_NAME"
[[ "$(read_key CFBundleIdentifier)" == "$BUNDLE_ID" ]] ||
    fail "CFBundleIdentifier must be $BUNDLE_ID"
[[ "$(read_key CFBundleName)" == "$APP_NAME" ]] ||
    fail "CFBundleName must be $APP_NAME"
[[ "$(read_key CFBundlePackageType)" == "APPL" ]] ||
    fail "CFBundlePackageType must be APPL"
[[ "$(read_key LSMinimumSystemVersion)" == "15.0" ]] ||
    fail "LSMinimumSystemVersion must match Package.swift"
[[ "$(read_key NSPrincipalClass)" == "NSApplication" ]] ||
    fail "NSPrincipalClass must be NSApplication"
[[ "$(read_key LSUIElement)" == "true" ]] ||
    fail "LSUIElement must be true for the menu-bar accessory"

microphone_copy="$(read_key NSMicrophoneUsageDescription)"
[[ "$microphone_copy" == *"Voice Console"* ]] ||
    fail "microphone purpose copy must name Voice Console"
[[ "$microphone_copy" == *"never retains the audio"* ]] ||
    fail "microphone purpose copy must state the no-retention guarantee"

if read_key NSAppleEventsUsageDescription >/dev/null 2>&1; then
    fail "Apple Events purpose string is unnecessary for the approved integration"
fi

if read_key NSScreenCaptureUsageDescription >/dev/null 2>&1; then
    fail "Screen Recording purpose string is forbidden in v1"
fi

/usr/bin/file "$APP_BINARY" | /usr/bin/grep -q "Mach-O" ||
    fail "bundle executable is not a Mach-O binary"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE" ||
    fail "bundle code signature is invalid"

[[ -f "$DIST_ARCHIVE" ]] ||
    fail "missing portable release archive at $DIST_ARCHIVE"

ARCHIVE_VALIDATION_ROOT="$(/usr/bin/mktemp -d -t CodexHUD.archive-validation)"
/usr/bin/ditto -x -k "$DIST_ARCHIVE" "$ARCHIVE_VALIDATION_ROOT" ||
    fail "portable release archive could not be extracted"

ARCHIVED_APP="$ARCHIVE_VALIDATION_ROOT/$APP_NAME.app"
ARCHIVED_INFO="$ARCHIVED_APP/Contents/Info.plist"
ARCHIVED_BINARY="$ARCHIVED_APP/Contents/MacOS/$APP_NAME"
[[ -d "$ARCHIVED_APP" ]] ||
    fail "portable release archive does not contain $APP_NAME.app"
[[ ! -e "$ARCHIVE_VALIDATION_ROOT/__MACOSX" ]] ||
    fail "portable release archive contains metadata sidecars"

/usr/bin/xattr -dr com.apple.FinderInfo "$ARCHIVED_APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$ARCHIVED_APP" 2>/dev/null || true
/usr/bin/codesign --verify --deep --strict "$ARCHIVED_APP" ||
    fail "archived app code signature is invalid"
/usr/bin/cmp -s "$APP_BINARY" "$ARCHIVED_BINARY" ||
    fail "archived executable does not match the installed app"
/usr/bin/cmp -s "$INFO_PLIST" "$ARCHIVED_INFO" ||
    fail "archived Info.plist does not match the installed app"

echo "Bundle validation passed: $APP_BUNDLE"
echo "Release archive validation passed: $DIST_ARCHIVE"
