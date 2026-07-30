#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURE_DIR="$ROOT_DIR/QA/VisualFixtures"
ARTIFACT_DIR="$ROOT_DIR/QA/ReviewArtifacts"
OUTPUT="$ARTIFACT_DIR/hud_states_montage.png"

"$ROOT_DIR/script/validate_visual_fixtures.sh"

FFMPEG="${CODEX_HUD_FFMPEG:-/opt/homebrew/bin/ffmpeg}"
if [[ ! -x "$FFMPEG" ]]; then
    FFMPEG="$(command -v ffmpeg || true)"
fi
[[ -n "$FFMPEG" && -x "$FFMPEG" ]] || {
    echo "Review montage failed: ffmpeg is unavailable." >&2
    exit 1
}

mkdir -p "$ARTIFACT_DIR"

"$FFMPEG" -hide_banner -loglevel error -y \
    -i "$FIXTURE_DIR/dormant.png" \
    -i "$FIXTURE_DIR/connecting.png" \
    -i "$FIXTURE_DIR/listening.png" \
    -i "$FIXTURE_DIR/thinking.png" \
    -i "$FIXTURE_DIR/speaking.png" \
    -i "$FIXTURE_DIR/approval.png" \
    -i "$FIXTURE_DIR/result.png" \
    -i "$FIXTURE_DIR/recoverableError.png" \
    -filter_complex \
    "color=c=0x111318:s=1936x2336[base]; \
    [base][0:v]overlay=x=(968-w)/2:y=(584-h)/2[b0]; \
    [b0][1:v]overlay=x=968+(968-w)/2:y=(584-h)/2[b1]; \
    [b1][2:v]overlay=x=(968-w)/2:y=584+(584-h)/2[b2]; \
    [b2][3:v]overlay=x=968+(968-w)/2:y=584+(584-h)/2[b3]; \
    [b3][4:v]overlay=x=(968-w)/2:y=1168+(584-h)/2[b4]; \
    [b4][5:v]overlay=x=968+(968-w)/2:y=1168+(584-h)/2[b5]; \
    [b5][6:v]overlay=x=(968-w)/2:y=1752+(584-h)/2[b6]; \
    [b6][7:v]overlay=x=968+(968-w)/2:y=1752+(584-h)/2" \
    -frames:v 1 \
    "$OUTPUT"

echo "Created review montage: $OUTPUT"
