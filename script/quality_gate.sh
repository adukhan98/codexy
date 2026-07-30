#!/usr/bin/env bash
set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
QUALITY_BUILD_PATH="${CODEX_HUD_QUALITY_BUILD_PATH:-$ROOT_DIR/.build/codex-hud-quality}"
FAILURES=()
PASSES=0

run_check() {
    local label="$1"
    shift

    echo
    echo "==> $label"
    if "$@"; then
        PASSES=$((PASSES + 1))
    else
        FAILURES+=("$label")
    fi
}

check_shell_syntax() {
    local script_file
    while IFS= read -r -d '' script_file; do
        /bin/bash -n "$script_file"
    done < <(/usr/bin/find "$ROOT_DIR/script" -type f -name '*.sh' -print0)
}

describe_package() {
    swift package \
        --package-path "$ROOT_DIR" \
        --scratch-path "$QUALITY_BUILD_PATH" \
        describe \
        --type json >/dev/null
}

run_tests() {
    SWIFT_DETERMINISTIC_HASHING=1 \
        "$ROOT_DIR/script/swift_test.sh" \
            --scratch-path "$QUALITY_BUILD_PATH" \
            --jobs 1
}

build_release_bundle() {
    CODEX_HUD_SCRATCH_PATH="$QUALITY_BUILD_PATH" \
        "$ROOT_DIR/script/build_and_run.sh" --stage --release
}

check_diff_whitespace() {
    if /usr/bin/git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        /usr/bin/git -C "$ROOT_DIR" diff --check
    fi
}

run_check "Shell syntax" check_shell_syntax
run_check "Swift package graph" describe_package
run_check "Source privacy and integration invariants" \
    "$ROOT_DIR/script/validate_source_contracts.sh"
run_check "Installed Codex app-server protocol classification" \
    "$ROOT_DIR/script/validate_app_server_protocol.sh"
run_check "Swift Testing contract suite" run_tests
run_check "Release build and app staging" build_release_bundle
run_check "Bundle metadata, privacy, and signature" \
    "$ROOT_DIR/script/validate_app_bundle.sh"
run_check "Deterministic visual fixtures" \
    "$ROOT_DIR/script/validate_visual_fixtures.sh"
run_check "Patch whitespace" check_diff_whitespace

echo
if ((${#FAILURES[@]} > 0)); then
    echo "QUALITY GATE FAILED: $PASSES checks passed; ${#FAILURES[@]} failed." >&2
    for failure in "${FAILURES[@]}"; do
        echo "  - $failure" >&2
    done
    exit 1
fi

echo "QUALITY GATE PASSED: $PASSES checks passed."
