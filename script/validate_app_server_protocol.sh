#!/usr/bin/env bash
set -euo pipefail

codex_executable=""
for application in \
    "/Applications/ChatGPT.app" \
    "/Applications/Codex.app"
do
    candidate="$application/Contents/Resources/codex"
    if [[ -x "$candidate" ]]; then
        codex_executable="$candidate"
        break
    fi
done

if [[ -z "$codex_executable" ]]; then
    echo "Protocol contract failed: the official bundled Codex executable is unavailable." >&2
    exit 1
fi

schema_dir="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/CodexHUD-protocol.XXXXXX")"
cleanup() {
    /bin/rm -rf "$schema_dir"
}
trap cleanup EXIT

"$codex_executable" app-server generate-ts \
    --experimental \
    --out "$schema_dir" >/dev/null

server_request="$schema_dir/ServerRequest.ts"
if [[ ! -f "$server_request" ]]; then
    echo "Protocol contract failed: Codex did not generate ServerRequest.ts." >&2
    exit 1
fi

actual_methods="$(
    LC_ALL=C /usr/bin/env rg -o '"method": "[^"]+"' "$server_request" |
        /usr/bin/sed -E 's/.*"method": "([^"]+)"/\1/' |
        /usr/bin/sort -u
)"
expected_methods="$(
    /usr/bin/printf '%s\n' \
        "account/chatgptAuthTokens/refresh" \
        "applyPatchApproval" \
        "attestation/generate" \
        "currentTime/read" \
        "execCommandApproval" \
        "item/commandExecution/requestApproval" \
        "item/fileChange/requestApproval" \
        "item/permissions/requestApproval" \
        "item/tool/call" \
        "item/tool/requestUserInput" \
        "mcpServer/elicitation/request"
)"

if [[ "$actual_methods" != "$expected_methods" ]]; then
    echo "Protocol contract failed: the installed Codex app-server request surface drifted." >&2
    /usr/bin/diff -u \
        <(/usr/bin/printf '%s\n' "$expected_methods") \
        <(/usr/bin/printf '%s\n' "$actual_methods") >&2 || true
    exit 1
fi

client_request="$schema_dir/ClientRequest.ts"
server_notification="$schema_dir/ServerNotification.ts"
for required_method in \
    "initialize" \
    "account/read" \
    "getAuthStatus" \
    "thread/list" \
    "thread/read" \
    "thread/start" \
    "thread/resume" \
    "thread/name/set" \
    "turn/start" \
    "turn/interrupt" \
    "thread/realtime/start" \
    "thread/realtime/stop"
do
    if ! /usr/bin/env rg -Fq "\"method\": \"$required_method\"" \
        "$client_request"; then
        echo "Protocol contract failed: required client method $required_method is absent." >&2
        exit 1
    fi
done

for required_notification in \
    "thread/realtime/sdp" \
    "thread/realtime/started" \
    "thread/realtime/transcript/delta" \
    "thread/realtime/transcript/done" \
    "thread/realtime/error" \
    "thread/realtime/closed" \
    "item/started" \
    "item/fileChange/patchUpdated" \
    "turn/started" \
    "turn/completed" \
    "serverRequest/resolved" \
    "account/updated"
do
    if ! /usr/bin/env rg -Fq "\"method\": \"$required_notification\"" \
        "$server_notification"; then
        echo "Protocol contract failed: required notification $required_notification is absent." >&2
        exit 1
    fi
done

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
schema_digest="$(
    /usr/bin/python3 \
        "$script_dir/compute_protocol_schema_digest.py" \
        "$schema_dir"
)"

expected_schema_digest="bdc734ca14e693370726b6620060c9c4d4b2e238913663d602a64790beffc0d0 212"
if [[ "$schema_digest" != "$expected_schema_digest" ]]; then
    echo "Protocol contract failed: a used app-server schema shape drifted." >&2
    echo "Expected: $expected_schema_digest" >&2
    echo "Actual:   $schema_digest" >&2
    exit 1
fi

echo "Codex app-server contract passed (11 server requests; $schema_digest exact schema closure)."
