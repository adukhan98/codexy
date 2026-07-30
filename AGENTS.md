# Codex HUD Engineering Contract

Codex HUD is a private, native macOS companion for the official Codex app.

## Product invariants

- Use the user's authenticated Codex/ChatGPT subscription through the official
  bundled Codex app-server. Do not introduce an OpenAI API key or separate API
  billing.
- Keep the Codex window hidden unless the user explicitly opens it.
- Bind voice interactions to one dedicated task named `Voice Console`.
- Never retain microphone audio or a second transcript history.
- Require explicit confirmation for destructive or externally visible actions.
- Do not require Screen Recording unless Accessibility-only control is proven insufficient and the user approves the expansion.

## Architecture

- SwiftUI owns visual state and view composition.
- AppKit owns only behavior SwiftUI cannot express cleanly: the non-activating floating panel, screen placement, and low-level event integration.
- Platform integrations live behind protocols so the state machine can be tested without macOS permissions.
- Prefer the official app-server realtime protocol over Accessibility automation.
  Accessibility is a narrow fallback for opening the corresponding desktop task.
- The app is a menu-bar accessory and stages as a real `.app` bundle.

## Quality bar

- Run `./script/quality_gate.sh` before declaring a checkpoint complete.
- Do not delete, skip, weaken, or narrow tests to make a gate pass.
- Every HUD state must have a deterministic render fixture and visual review.
- Respect Reduce Motion, Reduce Transparency, Increase Contrast, and VoiceOver.
- Keep idle CPU and memory modest on an M1 MacBook Air with 8 GB RAM.
- Treat clipped content, focus stealing, ambiguous microphone state, animation judder, and silent automation failure as release blockers.

## Ownership during parallel work

- Visual lane: `Sources/CodexHUD/Views/`, visual-only support types, and visual tests.
- Bridge lane: Codex and Accessibility files under `Sources/CodexHUD/Services/`.
- Reliability lane: `Tests/`, `script/quality_gate.sh`, and QA documentation.
- Root integrator: package manifest, app entrypoint, shared models/store, build script, and cross-lane integration.
