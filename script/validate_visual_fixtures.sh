#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/QA/VisualFixtures"
MANIFEST="$FIXTURE_DIR/manifest.sha256"
ACCESSIBILITY_FIXTURE_DIR="$ROOT_DIR/QA/AccessibilityFixtures"
ACCESSIBILITY_MANIFEST="$ACCESSIBILITY_FIXTURE_DIR/manifest.sha256"
PRODUCTION_ORB_FIXTURE_DIR="$ROOT_DIR/QA/ProductionOrbFixtures"
PRODUCTION_ORB_MANIFEST="$PRODUCTION_ORB_FIXTURE_DIR/manifest.sha256"
EXPECTED_ACCESSIBILITY_FIXTURES=(
    "approval-reduce-transparency.png 1032 728"
    "connecting-increase-contrast.png 428 264"
    "settings-720.png 1440 1440"
)

EXPECTED_FIXTURES=(
    "dormant.png 308 244"
    "connecting.png 428 264"
    "listening.png 428 264"
    "thinking.png 428 264"
    "speaking.png 428 264"
    "approval.png 1032 728"
    "result.png 968 584"
    "recoverableError.png 968 584"
)

EXPECTED_PRODUCTION_ORB_FIXTURES=(
    "connecting-production.png 428 264"
    "listening-production.png 428 264"
    "thinking-production.png 428 264"
    "speaking-production.png 428 264"
)

fail() {
    echo "Visual fixture validation failed: $1" >&2
    exit 1
}

[[ -d "$FIXTURE_DIR" ]] || fail "missing $FIXTURE_DIR"
[[ -f "$MANIFEST" ]] || fail "missing deterministic manifest.sha256"

actual_png_count="$(
    /usr/bin/find "$FIXTURE_DIR" -maxdepth 1 -type f -name '*.png' | /usr/bin/wc -l | /usr/bin/tr -d ' '
)"
[[ "$actual_png_count" == "${#EXPECTED_FIXTURES[@]}" ]] ||
    fail "expected ${#EXPECTED_FIXTURES[@]} PNGs, found $actual_png_count"

for fixture_contract in "${EXPECTED_FIXTURES[@]}"; do
    read -r filename expected_width expected_height <<<"$fixture_contract"
    fixture="$FIXTURE_DIR/$filename"
    [[ -f "$fixture" ]] || fail "missing $filename"

    file_size="$(/usr/bin/stat -f '%z' "$fixture")"
    ((file_size >= 300)) || fail "$filename is suspiciously small ($file_size bytes)"

    width="$(
        /usr/bin/sips -g pixelWidth "$fixture" 2>/dev/null |
            /usr/bin/awk '/pixelWidth:/ { print $2 }'
    )"
    height="$(
        /usr/bin/sips -g pixelHeight "$fixture" 2>/dev/null |
            /usr/bin/awk '/pixelHeight:/ { print $2 }'
    )"
    [[ "$width" == "$expected_width" && "$height" == "$expected_height" ]] ||
        fail "$filename is ${width}x${height}; expected ${expected_width}x${expected_height}"
done

manifest_entry_count="$(
    /usr/bin/grep -Ec '^[0-9a-f]{64}  [^/]+[.]png$' "$MANIFEST" || true
)"
[[ "$manifest_entry_count" == "${#EXPECTED_FIXTURES[@]}" ]] ||
    fail "manifest must contain exactly ${#EXPECTED_FIXTURES[@]} local PNG hashes"

(
    cd "$FIXTURE_DIR"
    /usr/bin/shasum -a 256 -c manifest.sha256
) || fail "one or more fixture hashes drifted"

[[ -d "$ACCESSIBILITY_FIXTURE_DIR" ]] ||
    fail "missing $ACCESSIBILITY_FIXTURE_DIR"
[[ -f "$ACCESSIBILITY_MANIFEST" ]] ||
    fail "missing accessibility manifest.sha256"

accessibility_png_count="$(
    /usr/bin/find "$ACCESSIBILITY_FIXTURE_DIR" -maxdepth 1 -type f -name '*.png' |
        /usr/bin/wc -l |
        /usr/bin/tr -d ' '
)"
[[ "$accessibility_png_count" == "${#EXPECTED_ACCESSIBILITY_FIXTURES[@]}" ]] ||
    fail "expected ${#EXPECTED_ACCESSIBILITY_FIXTURES[@]} accessibility PNGs, found $accessibility_png_count"

for fixture_contract in "${EXPECTED_ACCESSIBILITY_FIXTURES[@]}"; do
    read -r filename expected_width expected_height <<<"$fixture_contract"
    fixture="$ACCESSIBILITY_FIXTURE_DIR/$filename"
    [[ -f "$fixture" ]] || fail "missing accessibility fixture $filename"

    width="$(
        /usr/bin/sips -g pixelWidth "$fixture" 2>/dev/null |
            /usr/bin/awk '/pixelWidth:/ { print $2 }'
    )"
    height="$(
        /usr/bin/sips -g pixelHeight "$fixture" 2>/dev/null |
            /usr/bin/awk '/pixelHeight:/ { print $2 }'
    )"
    [[ "$width" == "$expected_width" && "$height" == "$expected_height" ]] ||
        fail "$filename is ${width}x${height}; expected ${expected_width}x${expected_height}"
done

accessibility_manifest_entry_count="$(
    /usr/bin/grep -Ec '^[0-9a-f]{64}  [^/]+[.]png$' \
        "$ACCESSIBILITY_MANIFEST" || true
)"
[[ "$accessibility_manifest_entry_count" == "${#EXPECTED_ACCESSIBILITY_FIXTURES[@]}" ]] ||
    fail "accessibility manifest must contain exactly ${#EXPECTED_ACCESSIBILITY_FIXTURES[@]} local PNG hashes"

(
    cd "$ACCESSIBILITY_FIXTURE_DIR"
    /usr/bin/shasum -a 256 -c manifest.sha256
) || fail "the accessibility fixture hash drifted"

[[ -d "$PRODUCTION_ORB_FIXTURE_DIR" ]] ||
    fail "missing $PRODUCTION_ORB_FIXTURE_DIR"
[[ -f "$PRODUCTION_ORB_MANIFEST" ]] ||
    fail "missing production orb manifest.sha256"

production_orb_png_count="$(
    /usr/bin/find \
        "$PRODUCTION_ORB_FIXTURE_DIR" \
        -maxdepth 1 \
        -type f \
        -name '*.png' |
        /usr/bin/wc -l |
        /usr/bin/tr -d ' '
)"
[[ "$production_orb_png_count" == "${#EXPECTED_PRODUCTION_ORB_FIXTURES[@]}" ]] ||
    fail "expected ${#EXPECTED_PRODUCTION_ORB_FIXTURES[@]} production orb PNGs, found $production_orb_png_count"

for fixture_contract in "${EXPECTED_PRODUCTION_ORB_FIXTURES[@]}"; do
    read -r filename expected_width expected_height <<<"$fixture_contract"
    fixture="$PRODUCTION_ORB_FIXTURE_DIR/$filename"
    [[ -f "$fixture" ]] || fail "missing production orb fixture $filename"

    width="$(
        /usr/bin/sips -g pixelWidth "$fixture" 2>/dev/null |
            /usr/bin/awk '/pixelWidth:/ { print $2 }'
    )"
    height="$(
        /usr/bin/sips -g pixelHeight "$fixture" 2>/dev/null |
            /usr/bin/awk '/pixelHeight:/ { print $2 }'
    )"
    [[ "$width" == "$expected_width" && "$height" == "$expected_height" ]] ||
        fail "$filename is ${width}x${height}; expected ${expected_width}x${expected_height}"
done

production_orb_manifest_entry_count="$(
    /usr/bin/grep -Ec \
        '^[0-9a-f]{64}  [^/]+[.]png$' \
        "$PRODUCTION_ORB_MANIFEST" ||
        true
)"
[[ "$production_orb_manifest_entry_count" == "${#EXPECTED_PRODUCTION_ORB_FIXTURES[@]}" ]] ||
    fail "production orb manifest must contain exactly ${#EXPECTED_PRODUCTION_ORB_FIXTURES[@]} local PNG hashes"

(
    cd "$PRODUCTION_ORB_FIXTURE_DIR"
    /usr/bin/shasum -a 256 -c manifest.sha256
) || fail "a production orb fixture hash drifted"

echo "Visual fixture validation passed: ${#EXPECTED_FIXTURES[@]} states + ${#EXPECTED_ACCESSIBILITY_FIXTURES[@]} accessibility layouts + ${#EXPECTED_PRODUCTION_ORB_FIXTURES[@]} production orb frames"
