# Codex HUD

## Outcome

Codex HUD provides a beautiful top-centre voice interface for Codex while the
main Codex window remains hidden. A single global shortcut or click starts and
stops a continuous hands-free session.

## Locked decisions

- Private macOS companion, not a public App Store product.
- Native SwiftUI + AppKit, not Electron.
- Uses the official Codex app-server and existing subscription; no OpenAI API key.
- Accepts only a macOS-signed `com.openai.codex` bundle and bundled `codex`
  executable issued to OpenAI Team ID `2DC432GLL2`.
- Runs as a lightweight menu-bar accessory and launches at login.
- Default shortcut: Shift-Option-Command-Space, customizable later. The extra
  Shift avoids Apple’s reserved Option-Command-Space Finder search shortcut.
- A tiny dormant orb remains visible while idle and can be hidden temporarily.
- One dedicated Codex task named `Voice Console` acts as a command centre for
  inspecting, creating, and handing off work to other Codex tasks.
- Codex replies aloud. Speaking during playback interrupts it.
- Long output and links expand into a compact HUD card. Approvals use a larger
  review card with the complete exact payload; the main Codex window never
  steals focus.
- Microphone permission is required. Accessibility is an optional fallback for
  opening the matching desktop task. Screen Recording is excluded.
- No audio recordings or duplicate transcript archive.
- Lock, display sleep, and cold launch into an inactive session fail closed:
  no voice start, focus, or visible HUD is allowed until the full public
  macOS session/display snapshot is verified active.

## HUD state model

1. `dormant`: tiny ready orb; microphone off.
2. `connecting`: binding to the official Codex app and Voice Console task.
3. `listening`: microphone live; amplitude-reactive orb and unmistakable label.
4. `thinking`: request accepted; calm progress motion.
5. `speaking`: Codex responding aloud; barge-in remains available.
6. `approval`: explicit approve/reject review card with complete scrollable
   command, permission, path/diff, and JSON context.
7. `result`: compact excerpt with `Open in Codex`.
8. `recoverableError`: microphone paused and one precise repair action.

## Acceptance scenario

The release candidate must:

1. Launch as a real `.app` and remain available from the menu bar.
2. Toggle a session with Shift-Option-Command-Space and by clicking the orb.
3. Enter the listening state within 500 ms after an already-warm activation.
4. Continue for 15 minutes without focus stealing.
5. Support barge-in while Codex is speaking.
6. Create or inspect another Codex task through Voice Console.
7. Recover after the Codex app is quit and reopened.
8. Retain no audio and no transcript outside Codex.
9. Pass automated tests, bundle checks, deterministic state screenshots, and
   independent hostile visual review with no critical or major findings.

## Official integration boundary

The Codex binary bundled in the installed desktop app exposes an experimental
subscription-authenticated app-server protocol. Local verification found:

- `thread/start`, `thread/list`, and `thread/resume` for Voice Console
- `thread/realtime/start` and `thread/realtime/stop` using the current v3 WebRTC
  transport and the `cove` voice
- realtime SDP, started, transcript delta/done, error, and closed notifications
- exact command, file-change, permission, legacy, and task-tool approval
  requests, all guarded by the `untrusted` approval policy
- 11 supported server-request methods and a recursively verified 212-file
  generated TypeScript schema closure

This is a materially stronger primary integration than screen-coordinate or
DOM automation. Because the realtime methods are explicitly experimental, all
method names and response shapes must remain isolated behind a compatibility
layer. Unsupported versions must produce a precise repair state rather than
silently falling back to a fake conversation.
