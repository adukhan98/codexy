# Build, Permission, and Run Notes

Codex HUD is a SwiftPM GUI executable. `script/build_and_run.sh` is the single
supported local run entrypoint; it stages and signs outside File Provider,
installs the runnable app at `~/Applications/CodexHUD.app`, and writes the
portable release artifact to `dist/CodexHUD.app.zip`. The Codex desktop Run
button is wired to that script through `.codex/environments/environment.toml`.

Supported modes:

- `./script/build_and_run.sh`
- `./script/build_and_run.sh --verify`
- `./script/build_and_run.sh --debug`
- `./script/build_and_run.sh --logs`
- `./script/build_and_run.sh --telemetry`
- `./script/build_and_run.sh --stage --release`

`script/swift_test.sh` is the test entrypoint. The installed Command Line Tools
contain Swift Testing in their developer-framework directory but do not add that
directory or the macro plugin to plain `swift test`. The wrapper discovers the
active developer directory, validates those toolchain components, and supplies
the framework, macro, linker, and runtime search paths. It fails with an exact
missing-component diagnostic instead of silently skipping tests.

The bundle is an `LSUIElement` accessory and contains only the required
microphone purpose string. Voice uses the `codex` executable inside the
installed, official Codex bundle, launches its app-server, calls
`thread/realtime/start`, and hosts the returned local realtime surface in
WKWebView. It inherits the official app’s signed-in subscription and never
accepts a separate API key.

Discovery does not trust a registered bundle identifier or application path by
itself. The selected desktop bundle must pass strict macOS static-code
validation for `com.openai.codex` and OpenAI Team ID `2DC432GLL2`; its bundled
`Contents/Resources/codex` executable must independently pass the same OpenAI
team requirement before it can be launched.

Subscription authentication is verified twice before a Voice Console is
prepared: `account/read` must return a ChatGPT account with
`requiresOpenaiAuth == true`, and `getAuthStatus` must report Codex-managed
ChatGPT authentication without requesting or returning a token. An auth-mode
change, disconnect, unsupported privileged request, or failed verification
invalidates the session and fails closed.

Every Voice Console and coordinated-task start or resume uses
`approvalPolicy: "untrusted"`, `approvalsReviewer: "user"`, and
`sandbox: "workspace-write"`. The bridge has an exact allowlist for all 11
app-server requests it can receive. Commands, permissions, legacy approvals,
and file changes are scoped to the Voice Console or an explicitly authorized
child task. File approvals are withheld unless the matching latest path and
diff payload has arrived; approval cards display the complete request as
scrollable, pretty-printed JSON without truncation.

`script/validate_app_server_protocol.sh` regenerates the installed app-server
TypeScript schema, checks the required request and notification surface, and
verifies a recursive digest of the complete imported protocol schema. This
turns an installed Codex protocol change into a release-gate failure instead of
silently accepting drift.

Open in Codex uses the official `codex://threads/<id>` deep link. macOS
Accessibility control does not use an
`NSAccessibilityUsageDescription` Info.plist key. Accessibility is optional and
limited to a fallback for that explicit convenience action; it is not a voice
dependency. If the fallback uses Accessibility, trust is checked through
`AXIsProcessTrustedWithOptions` rather than an invented purpose key. Apple
Events is not part of the integration and no Apple Events purpose key belongs
in the bundle.

`NSMicrophoneUsageDescription` explicitly says audio is not retained.
`NSScreenCaptureUsageDescription` is forbidden, as are ScreenCaptureKit APIs,
audio-file writers, OpenAI API credentials/endpoints, and persisted
audio/transcript keys.

Realtime transcript presentation uses a bounded newest-eight transient stream;
the lossless stream is reserved for protocol duties and is not retained as a
second transcript history. Entering approval waits for an acknowledged
microphone-and-output mute barrier before showing action controls. Lock and
display sleep use the same acknowledgement with a generation guard so a late
confirmation cannot mute a resumed session. Any acknowledgement failure tears
down the realtime WebKit surface and fails closed. Stop, terminal failure, and
auth failure also remove the message handler, detach and close the hidden
window, stop loading, and release the WKWebView.

Cold launch is fail-closed too. A process-lifetime lifecycle service registers
negative lock/sleep observers before sampling the public CoreGraphics session
and display state. Positive wake/activation signals never directly mark the
session usable; they trigger bounded revalidation of login state, trusted
frontmost-app identity, and an online, active, awake display. The panel,
compositor, model, and media suspension path consume that single result.
Starting or repairing voice while interaction is inactive performs no bridge or
media work. If lock wins during startup, a suspension latch survives dormant
teardown so a late realtime-start notification cannot unmute input.

Coordinated task turns are tracked only for the active Voice Console
generation. Stop or failure cancels tool execution, interrupts every started
child turn with a bounded timeout, declines unresolved approvals, and clears
transient file-change context. A child-task approval temporarily pauses Voice
media and restores the exact pre-approval presentation and media policy only
while that originating session remains valid.

Ad-hoc signing is suitable for private local development. A stable Developer ID
identity can be selected with `CODEX_HUD_SIGNING_IDENTITY` when a stable
long-lived installation is desired:

```sh
CODEX_HUD_SIGNING_IDENTITY="Developer ID Application: Example" \
    ./script/build_and_run.sh --verify --release
```

Permission grants can be invalidated when the app’s code identity changes.
Release acceptance must therefore be performed against the exact installed
build that is being reviewed. The release gate strictly verifies that installed
app, extracts the ZIP into a fresh temporary directory, verifies its signature,
and compares its executable and Info.plist with the installed copy.

The runnable app intentionally does not live inside `dist`. This workspace is
File Provider-backed, and macOS can continuously attach `com.apple.FinderInfo`
to an `.app` stored there, causing strict signature verification to fail even
when the sealed payload is unchanged. A ZIP is stable in the synced workspace;
the installed app remains strictly verifiable in the standard per-user
Applications directory.
