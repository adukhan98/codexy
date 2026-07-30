#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH_PATH="${CODEX_HUD_FIXTURE_BUILD_PATH:-$ROOT_DIR/.build/codex-hud-fixtures}"

CODEX_HUD_RECORD_FIXTURES=1 \
    "$ROOT_DIR/script/swift_test.sh" \
        --scratch-path "$SCRATCH_PATH" \
        --jobs 1 \
        --filter VisualFixtureTests

"$ROOT_DIR/script/validate_visual_fixtures.sh"
