#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/Sources"

duplicate_swift_file="$(
    /usr/bin/find "$ROOT_DIR/Sources" "$ROOT_DIR/Tests" \
        -type f \
        -name '* [0-9]*.swift' \
        -print \
        -quit
)"
if [[ -n "$duplicate_swift_file" ]]; then
    echo "Source contract failed: stale duplicate Swift file: $duplicate_swift_file" >&2
    exit 1
fi

fail_with_matches() {
    local message="$1"
    local pattern="$2"
    echo "Source contract failed: $message" >&2
    /usr/bin/env rg -n "$pattern" "$SOURCE_DIR" >&2 || true
    exit 1
}

if /usr/bin/env rg -n \
    'OPENAI_API_KEY|api[.]openai[.]com|sk-proj-|sk-[A-Za-z0-9]{20,}' \
    "$SOURCE_DIR" >/dev/null; then
    fail_with_matches \
        "Codex HUD must use the signed-in official app, never API credentials." \
        'OPENAI_API_KEY|api[.]openai[.]com|sk-proj-|sk-[A-Za-z0-9]{20,}'
fi

if /usr/bin/env rg -n \
    'ScreenCaptureKit|SCStream|CGDisplayStream|CGWindowListCreateImage|NSScreenCaptureUsageDescription' \
    "$SOURCE_DIR" >/dev/null; then
    fail_with_matches \
        "Screen Recording APIs are outside the approved v1 permission boundary." \
        'ScreenCaptureKit|SCStream|CGDisplayStream|CGWindowListCreateImage|NSScreenCaptureUsageDescription'
fi

if /usr/bin/env rg -n \
    'NSAppleScript|NSAppleEventDescriptor|AECreateAppleEvent|NSAppleEventsUsageDescription' \
    "$SOURCE_DIR" >/dev/null; then
    fail_with_matches \
        "Apple Events is unnecessary for deep-link and optional AX integration." \
        'NSAppleScript|NSAppleEventDescriptor|AECreateAppleEvent|NSAppleEventsUsageDescription'
fi

if /usr/bin/env rg -n \
    'AVAudioFile|ExtAudioFile|AudioFileCreateWithURL|AudioFileWriteBytes' \
    "$SOURCE_DIR" >/dev/null; then
    fail_with_matches \
        "Microphone audio persistence is forbidden." \
        'AVAudioFile|ExtAudioFile|AudioFileCreateWithURL|AudioFileWriteBytes'
fi

if /usr/bin/env rg -n \
    'UserDefaults[^[:cntrl:]]*(transcript|audio)|(@AppStorage|SceneStorage)[^[:cntrl:]]*(transcript|audio)' \
    "$SOURCE_DIR" >/dev/null; then
    fail_with_matches \
        "Codex HUD must not persist transcript or audio state." \
        'UserDefaults[^[:cntrl:]]*(transcript|audio)|(@AppStorage|SceneStorage)[^[:cntrl:]]*(transcript|audio)'
fi

if ! /usr/bin/env rg -q '"Voice Console"' "$SOURCE_DIR"; then
    echo "Source contract failed: dedicated task name \"Voice Console\" is absent." >&2
    exit 1
fi

if ! /usr/bin/env rg -q \
    'Codex[.]app|com[.]openai[.]codex|Contents[^[:cntrl:]]*Resources[^[:cntrl:]]*codex' \
    "$SOURCE_DIR"; then
    echo "Source contract failed: discovery of the official bundled Codex executable is absent." >&2
    exit 1
fi

installation_source="$SOURCE_DIR/CodexHUD/Services/CodexAccessibilityLauncher.swift"
for signature_contract in \
    'import Security' \
    'SecStaticCodeCreateWithPath' \
    'SecRequirementCreateWithString' \
    'SecStaticCodeCheckValidity' \
    'kSecCSStrictValidate' \
    '2DC432GLL2'
do
    if ! /usr/bin/env rg -Fq "$signature_contract" "$installation_source"; then
        echo "Source contract failed: official Codex signature validation is incomplete ($signature_contract)." >&2
        exit 1
    fi
done

if ! /usr/bin/env rg -q '"app-server"' "$SOURCE_DIR"; then
    echo "Source contract failed: the bundled Codex app-server launch is absent." >&2
    exit 1
fi

if ! /usr/bin/env rg -q '"account/read"' "$SOURCE_DIR"; then
    echo "Source contract failed: subscription authentication is not verified." >&2
    exit 1
fi

if ! /usr/bin/env rg -q '"thread/realtime/start"' "$SOURCE_DIR"; then
    echo "Source contract failed: thread/realtime/start integration is absent." >&2
    exit 1
fi

if ! /usr/bin/env rg -q 'import WebKit|WKWebView' "$SOURCE_DIR"; then
    echo "Source contract failed: the local WKWebView realtime transport is absent." >&2
    exit 1
fi

transport_source="$SOURCE_DIR/CodexHUD/Services/RealtimeWebRTCTransport.swift"
get_user_media_line="$(
    (
        /usr/bin/env rg -n -m 1 \
            'inputStream = await navigator[.]mediaDevices[.]getUserMedia' \
            "$transport_source" || true
    ) |
        /usr/bin/cut -d: -f1
)"
initial_mute_line="$(
    (
        /usr/bin/env rg -n -m 1 \
            'track[.]enabled = false' \
            "$transport_source" || true
    ) |
        /usr/bin/cut -d: -f1
)"
audio_context_line="$(
    (
        /usr/bin/env rg -n -m 1 \
            'audioContext = new AudioContext' \
            "$transport_source" || true
    ) |
        /usr/bin/cut -d: -f1
)"
if [[
    -z "$get_user_media_line" ||
    -z "$initial_mute_line" ||
    -z "$audio_context_line" ||
    "$initial_mute_line" -le "$get_user_media_line" ||
    "$initial_mute_line" -ge "$audio_context_line"
]]; then
    echo "Source contract failed: new microphone tracks must be disabled immediately after getUserMedia and before later media work." >&2
    exit 1
fi

if ! /usr/bin/env rg -q \
    'websiteDataStore = [.]nonPersistent[(][)]' \
    "$transport_source"; then
    echo "Source contract failed: the realtime WKWebView must use a non-persistent data store." >&2
    exit 1
fi

if ! /usr/bin/env rg -q 'func confirmMediaMuted[(][)] async throws' \
    "$transport_source" ||
   ! /usr/bin/env rg -q 'removeScriptMessageHandler' "$transport_source" ||
   ! /usr/bin/env rg -q 'self[.]webView = nil' "$transport_source" ||
   ! /usr/bin/env rg -q 'mediaWindow = nil' "$transport_source"; then
    echo "Source contract failed: media mute must be acknowledged and stop must destroy the WKWebView capture surface." >&2
    exit 1
fi

if /usr/bin/env rg -n 'approvalPolicy = "on-request"' "$SOURCE_DIR" >/dev/null; then
    fail_with_matches \
        "Voice-controlled tasks must not let the model choose whether mutations need approval." \
        'approvalPolicy = "on-request"'
fi

untrusted_policy_count="$(
    /usr/bin/env rg -o 'approvalPolicy = "untrusted"' "$SOURCE_DIR" |
        /usr/bin/wc -l |
        /usr/bin/tr -d ' '
)"
if [[ "$untrusted_policy_count" -lt 4 ]]; then
    echo "Source contract failed: Voice Console start/resume and coordinated task start/resume must all use untrusted approval." >&2
    exit 1
fi

echo "Source privacy and integration contracts passed."
