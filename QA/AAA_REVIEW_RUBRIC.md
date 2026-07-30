# Codex HUD Hostile AAA Review Rubric

This rubric is intentionally adversarial. “Looks promising,” “works on my
machine,” and “probably fine” are not passing evidence. A release candidate
passes only with zero Critical and zero Major findings across every captured HUD
state and the full acceptance session.

## Severity

- **Critical:** microphone safety is ambiguous; Codex or another app steals
  focus; a destructive or externally visible action can proceed without an
  explicit decision; audio or transcript data is retained; the app crashes,
  hangs, silently loses automation, requests Screen Recording, or uses separate
  API billing.
- **Major:** clipping, overlap, unreadable copy, broken hierarchy, nonfunctional
  control, incorrect task binding, failed recovery, visible animation judder,
  inaccessible state, inconsistent geometry, or a visual result materially below
  polished first-party macOS quality.
- **Minor:** detectable but non-blocking polish debt such as a slightly uneven
  optical alignment, weak microcopy, or a small color/spacing inconsistency.
- **Note:** optional refinement whose absence would not be noticed in ordinary
  use.

Critical and Major findings block the checkpoint. Minor findings require an
owner and an explicit disposition before release.

## Evidence package

Reviewers must have:

1. The eight deterministic 2x PNG fixtures and their verified SHA-256 manifest.
2. Four deterministic production-compositor orb frames—connecting, listening,
   thinking, and speaking—plus Reduce Transparency, Increase Contrast, and
   large Settings fixtures with a verified manifest.
3. A 60 fps screen recording that visits all transitions at normal speed and
   at 0.25x playback.
4. Reduce Motion, Reduce Transparency, Increase Contrast, and VoiceOver passes.
5. A 15-minute live session log with focus, process, CPU, memory, and recovery
   observations.
6. Cold-launch, warm-toggle, Codex-quit, permission-denied, approval, result,
   and barge-in evidence.
7. Strict signature verification for `~/Applications/CodexHUD.app` plus a fresh
   extraction and equivalence check of `dist/CodexHUD.app.zip`.

Do not approve visuals from a SwiftUI preview alone.

## Static visual inspection

Inspect every fixture at 100%, 200%, and against both a light and dark desktop:

- No edge clipping, unintended transparency seams, halo banding, muddy blur,
  one-pixel discontinuities, or asymmetric corners.
- The orb reads as dimensional and intentional rather than a generic radial
  gradient. Highlights, core, rim, grain, and shadow agree on one light model.
- Materials remain legible over high-frequency, bright, and near-black
  wallpapers.
- Text uses a stable baseline grid, correct optical centering, clean truncation,
  and sufficient contrast. No label competes with the current safety state.
- The microphone state is understandable in under one second without relying
  on color alone.
- Approval is unmistakably a decision, with destructive/external context and
  two visually distinct, fully visible actions.
- Error copy names the failure and the repair. It never implies work continued.
- Buttons have consistent hit regions, corner language, hover treatment,
  pressed treatment, keyboard focus, and VoiceOver names.
- Result and repair cards fit the 388-by-164 point contract. The approval card
  fits its 420-by-236 point review contract, exposes a 120-point scroll
  viewport, and never cramps, clips, or truncates the exact authorization
  payload or either decision.
- Dormant and active capsules remain top-centre and optically balanced on
  notched and notchless displays.

Any reviewer instinct to say “users probably won’t notice” is a prompt to zoom
in and classify the defect, not dismiss it.

## Motion and physics inspection

- Capture at 60 fps; reject dropped or duplicated frames attributable to the
  app.
- Expansion preserves the orb’s perceived mass and origin. Nothing teleports.
- Springs settle once, without rubbery overshoot, mechanical linearity, or
  micro-jitter at rest.
- Listening response follows amplitude quickly but filters noise; silence never
  looks broken and loud input never clips into the capsule edge.
- Thinking motion is calm and non-audio-reactive. Speaking is visually distinct
  from listening.
- Barge-in changes speaking to listening immediately and never allows stale
  speaking motion to linger.
- Repeated shortcut presses cannot stack transitions or leave an impossible
  intermediate state.
- Reduce Motion removes spatial/continuous motion while preserving immediate
  state comprehension.
- Animation never delays microphone shutdown, approval, or error presentation.

## Interaction and focus inspection

- The global shortcut and orb click are behaviorally identical.
- Warm activation reaches unmistakable listening within 500 ms.
- The panel never steals main or key status automatically, enters the
  Command-Tab app cycle, moves Spaces unexpectedly, or raises the official
  Codex window. The explicit **Focus HUD Controls** command may make an expanded
  approval, result, or repair card key temporarily; Escape, completing an
  action, or any compact transition must restore the previously focused app.
- Clicking controls works without activating an unrelated app or losing the
  current workspace.
- Escape/stop behavior is immediate, idempotent, and leaves microphone level at
  zero.
- The idle orb may hide; an active microphone may not be hidden accidentally.
- Open in Codex is the only user action allowed to reveal the dedicated task.

## Accessibility inspection

- VoiceOver announces “Codex voice HUD,” the current state, microphone status,
  complete approval context, and each action in a sensible order.
- No essential state depends on color, blur, transparency, animation, or audio.
- Increase Contrast produces decisive boundaries with no clipped strokes.
- Reduce Transparency replaces material with an opaque, intentional surface.
- Full Keyboard Access reaches every action with a visible focus indicator.
- [macOS Dynamic Type does not change user text
  size](https://developer.apple.com/documentation/swiftui/environmentvalues/dynamictypesize).
  Test the supported system text size together with Hover Text and Zoom;
  complete content and every control must remain discoverable, readable, and
  unclipped. If Codex HUD later adds an app-specific text-size control, its
  maximum size becomes a required deterministic fixture.

## Reliability and privacy inspection

- Denying microphone produces a precise repair card and no silent loop.
  Accessibility is optional and used only for the explicit Open Voice Console
  convenience action; denial must not break voice.
- The official bundled Codex app-server binds only to `Voice Console`, recovers
  the same task after its subprocess is killed, and times out visibly when the
  realtime surface is unavailable.
- The local WKWebView/WebRTC transport never navigates to an arbitrary remote
  page and leaves no retained microphone or transcript artifact.
- No API key, OpenAI network endpoint, Screen Recording API, audio-file writer,
  or transcript persistence exists in source or bundle behavior.
- The app is a signed `LSUIElement` `.app` with explicit microphone purpose
  copy and no unnecessary Apple Events or Screen Recording declaration.
- Idle CPU is effectively quiescent and idle memory remains modest on the
  target M1 MacBook Air with 8 GB RAM.
- Sleep/wake, display changes, Spaces, external displays, and rapid Codex
  restarts never strand an invisible live microphone.
- Launching while already locked or asleep produces no visible HUD, focus
  change, app-server child, WebRTC start, or microphone unmute. Wake restores
  visibility only after the complete system snapshot is verified active.

## Review record

Each finding must include:

- severity;
- fixture/state and exact timestamp when dynamic;
- expected versus observed behavior;
- screenshot or recording evidence;
- reproduction steps;
- owner;
- fix verification evidence.

The hostile reviewer signs off only after independently rerunning the relevant
proof. A developer saying a defect is fixed is not verification.
