#!/usr/bin/env bash
set -euo pipefail

APP_NAME="CodexHUD"
BUNDLE_ID="com.adnaankhan.CodexHUD"
MIN_SYSTEM_VERSION="15.0"
APP_VERSION="0.1.0"
BUILD_NUMBER="1"
MODE="run"
CONFIGURATION="debug"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
INSTALL_DIR="${CODEX_HUD_INSTALL_DIR:-$HOME/Applications}"
APP_BUNDLE="$INSTALL_DIR/$APP_NAME.app"
DIST_ARCHIVE="$DIST_DIR/$APP_NAME.app.zip"
LEGACY_DIST_APP="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
SCRATCH_PATH="${CODEX_HUD_SCRATCH_PATH:-$ROOT_DIR/.build/codex-hud-run}"
STAGING_ROOT=""

cleanup_staging() {
    if [[
        -n "$STAGING_ROOT" &&
        "$(/usr/bin/basename "$STAGING_ROOT")" == "CodexHUD.stage."* &&
        "$STAGING_ROOT" == /* &&
        -d "$STAGING_ROOT"
    ]]; then
        /bin/rm -rf "$STAGING_ROOT"
    fi
}
trap cleanup_staging EXIT

usage() {
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--stage] [--release]" >&2
}

for argument in "$@"; do
    case "$argument" in
        run)
            MODE="run"
            ;;
        --debug|debug)
            MODE="debug"
            ;;
        --logs|logs)
            MODE="logs"
            ;;
        --telemetry|telemetry)
            MODE="telemetry"
            ;;
        --verify|verify)
            MODE="verify"
            ;;
        --stage|stage)
            MODE="stage"
            ;;
        --release|release)
            CONFIGURATION="release"
            ;;
        --help|-h|help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

stop_running_app() {
    /usr/bin/pkill -x "$APP_NAME" >/dev/null 2>&1 || true

    for _ in {1..20}; do
        if ! /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            return
        fi
        /bin/sleep 0.05
    done

    echo "CodexHUD did not exit cleanly before rebuild." >&2
    exit 1
}

stage_app_bundle() {
    if [[ "$INSTALL_DIR" != /* || "$INSTALL_DIR" == "/" ]]; then
        echo "Install directory must be a specific absolute path: $INSTALL_DIR" >&2
        exit 1
    fi

    /bin/mkdir -p "$DIST_DIR" "$INSTALL_DIR"

    # Assemble and sign outside File Provider. Synced folders can continuously
    # reattach FinderInfo to .app roots, invalidating strict verification.
    STAGING_ROOT="$(/usr/bin/mktemp -d -t CodexHUD.stage)"
    local staged_app="$STAGING_ROOT/$APP_NAME.app"
    local staged_contents="$staged_app/Contents"
    local staged_macos="$staged_contents/MacOS"
    local staged_resources="$staged_contents/Resources"
    local staged_binary="$staged_macos/$APP_NAME"
    local staged_plist="$staged_contents/Info.plist"

    /bin/mkdir -p "$staged_macos" "$staged_resources"

    swift build \
        --configuration "$CONFIGURATION" \
        --product "$APP_NAME" \
        --scratch-path "$SCRATCH_PATH" \
        --jobs 1

    local bin_path
    bin_path="$(
        swift build \
            --show-bin-path \
            --configuration "$CONFIGURATION" \
            --scratch-path "$SCRATCH_PATH"
    )"
    local build_binary="$bin_path/$APP_NAME"

    if [[ ! -x "$build_binary" ]]; then
        echo "Built executable is missing: $build_binary" >&2
        exit 1
    fi

    # Never import Finder metadata, resource forks, quarantine state, or other
    # extended attributes into a code-signed bundle. Cloud-backed workspaces
    # can attach this metadata even to fresh SwiftPM build products.
    /bin/cp -X "$build_binary" "$staged_binary"
    /bin/chmod 755 "$staged_binary"

    while IFS= read -r -d '' resource_bundle; do
        /usr/bin/ditto \
            --norsrc \
            --noextattr \
            --noqtn \
            --noacl \
            "$resource_bundle" \
            "$staged_resources/$(/usr/bin/basename "$resource_bundle")"
    done < <(
        /usr/bin/find "$bin_path" -maxdepth 1 -type d -name '*.bundle' -print0
    )

    local icon_source="$ROOT_DIR/Sources/CodexHUD/Resources/AppIcon.icns"
    local icon_entry=""
    if [[ -f "$icon_source" ]]; then
        local icon_copy_source="$icon_source"
        local installed_icon="$APP_BUNDLE/Contents/Resources/AppIcon.icns"
        local icon_flags
        local source_icon_size
        local installed_icon_size=""
        icon_flags="$(/usr/bin/stat -f '%Sf' "$icon_source")"
        source_icon_size="$(/usr/bin/stat -f '%z' "$icon_source")"
        if [[ -f "$installed_icon" ]]; then
            installed_icon_size="$(/usr/bin/stat -f '%z' "$installed_icon")"
        fi
        if [[
            "$icon_flags" == *"dataless"* &&
            -f "$installed_icon" &&
            "$installed_icon_size" == "$source_icon_size"
        ]]; then
            # File Provider may evict the source asset between builds. Reuse
            # the same-size hydrated icon from this app's previous signed
            # installation so local staging never blocks on a cloud download.
            icon_copy_source="$installed_icon"
        fi
        /bin/cp -X "$icon_copy_source" "$staged_resources/AppIcon.icns"
        icon_entry=$'  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>'
    fi

    /bin/cat >"$staged_plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD_NUMBER</string>
$icon_entry
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>LSMultipleInstancesProhibited</key>
  <true/>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Codex HUD uses the microphone only while Voice Console is active so you can speak to Codex. Codex HUD never retains the audio.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

    /usr/bin/plutil -lint "$staged_plist" >/dev/null

    # Defensive final sanitation covers attributes created by the filesystem
    # while the bundle is assembled. This touches only the disposable staging
    # tree and runs before signing.
    /usr/bin/xattr -cr "$staged_app"

    local signing_identity="${CODEX_HUD_SIGNING_IDENTITY:--}"
    if [[ "$signing_identity" == "-" ]]; then
        if ! /usr/bin/codesign \
            --force \
            --deep \
            --sign - \
            --timestamp=none \
            --identifier "$BUNDLE_ID" \
            "$staged_app"; then
            echo "Code signing failed; staged bundle metadata follows:" >&2
            /usr/bin/xattr -lr "$staged_app" >&2 || true
            exit 1
        fi
    else
        if ! /usr/bin/codesign \
            --force \
            --deep \
            --sign "$signing_identity" \
            --identifier "$BUNDLE_ID" \
            "$staged_app"; then
            echo "Code signing failed; staged bundle metadata follows:" >&2
            /usr/bin/xattr -lr "$staged_app" >&2 || true
            exit 1
        fi
    fi
    /usr/bin/codesign --verify --deep --strict "$staged_app"

    local expected_bundle="$INSTALL_DIR/$APP_NAME.app"
    if [[ "$APP_BUNDLE" != "$expected_bundle" ]]; then
        echo "Refusing to replace unexpected bundle path: $APP_BUNDLE" >&2
        exit 1
    fi

    if [[ -e "$APP_BUNDLE" ]]; then
        /bin/rm -rf "$APP_BUNDLE"
    fi
    /bin/mv "$staged_app" "$APP_BUNDLE"

    # File Provider can attach FinderInfo to an .app at the moment it enters a
    # synced workspace. Those attributes are outside the signed payload, but
    # strict verification correctly rejects them. Remove only the two xattrs
    # prohibited by codesign, then prove the bundle remains valid in-place.
    /usr/bin/xattr -dr com.apple.FinderInfo "$APP_BUNDLE" 2>/dev/null || true
    /usr/bin/xattr -dr com.apple.ResourceFork "$APP_BUNDLE" 2>/dev/null || true
    if ! /usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"; then
        echo "Final bundle verification failed; installed metadata follows:" >&2
        /usr/bin/xattr -lr "$APP_BUNDLE" >&2 || true
        exit 1
    fi

    local staged_archive="$STAGING_ROOT/$APP_NAME.app.zip"
    /usr/bin/ditto \
        -c \
        -k \
        --keepParent \
        --norsrc \
        --noextattr \
        --noqtn \
        --noacl \
        "$APP_BUNDLE" \
        "$staged_archive"

    if [[ -e "$DIST_ARCHIVE" ]]; then
        /bin/rm -f "$DIST_ARCHIVE"
    fi
    /bin/mv "$staged_archive" "$DIST_ARCHIVE"

    # Remove the obsolete File Provider-hosted bundle only after both the
    # installed app and portable archive have been promoted successfully.
    if [[ -e "$LEGACY_DIST_APP" ]]; then
        /bin/rm -rf "$LEGACY_DIST_APP"
    fi

    cleanup_staging
    STAGING_ROOT=""
}

open_app() {
    /usr/bin/open -n "$APP_BUNDLE"
}

verify_process() {
    for _ in {1..50}; do
        if /usr/bin/pgrep -x "$APP_NAME" >/dev/null 2>&1; then
            echo "Verified $APP_NAME is running from $APP_BUNDLE"
            return
        fi
        /bin/sleep 0.1
    done

    echo "$APP_NAME did not remain running after launch." >&2
    exit 1
}

stop_running_app
stage_app_bundle

case "$MODE" in
    run)
        open_app
        ;;
    debug)
        exec /usr/bin/lldb -- "$APP_BINARY"
        ;;
    logs)
        open_app
        verify_process
        exec /usr/bin/log stream \
            --info \
            --style compact \
            --predicate "process == \"$APP_NAME\""
        ;;
    telemetry)
        open_app
        verify_process
        exec /usr/bin/log stream \
            --info \
            --style compact \
            --predicate "subsystem == \"$BUNDLE_ID\""
        ;;
    verify)
        "$ROOT_DIR/script/validate_app_bundle.sh" "$APP_BUNDLE"
        open_app
        verify_process
        ;;
    stage)
        "$ROOT_DIR/script/validate_app_bundle.sh" "$APP_BUNDLE"
        echo "Installed $APP_BUNDLE"
        echo "Archived $DIST_ARCHIVE"
        ;;
esac
