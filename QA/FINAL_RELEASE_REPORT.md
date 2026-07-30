# Codex HUD Release Candidate Report

Recorded on 2026-07-30 in America/Toronto.

## Exact artifacts

- Installed app: `~/Applications/CodexHUD.app`
- Portable archive: `dist/CodexHUD.app.zip`
- Bundle identifier: `com.adnaankhan.CodexHUD`
- Version: `0.1.0`
- Code-directory hash: `26fa4015bbe0da71ea295707cb297c2845db9e2d`
- Executable SHA-256:
  `1ff1681a0c9e41549d80434bfdd073759b161720d4f5481d1d9ad6fd7cb1f243`
- Info.plist SHA-256:
  `63f515e2826cf34b7ec8da23b37aed1ab6a84917cf07aeb809e0fbae16a678f8`
- ZIP SHA-256:
  `25a5c988bde1b86251327dc80bf3ebae608a139efd5990764ae44c2fc4705e0c`

The local release is ad-hoc signed for private installation. Strict deep
signature validation and the bundle/archive equivalence checks passed.

## Automated release gate

`CODEX_HUD_QUALITY_BUILD_PATH=/tmp/CodexHUDFinalQuality2
./script/quality_gate.sh`

- Result: 9/9 checks passed.
- Swift Testing: 120/120 tests across 10 suites passed.
- Installed app-server protocol: 11 server-request types classified.
- Recursive generated protocol closure:
  `bdc734ca14e693370726b6620060c9c4d4b2e238913663d602a64790beffc0d0`
  across 212 generated TypeScript files.
- Source privacy/integration invariants passed.
- Release build, staging, installed bundle validation, archive extraction,
  signature validation, and executable/Info.plist equivalence passed.
- Eight HUD states, three accessibility layouts, and four production orb
  frames matched deterministic fixtures.
- Hostile visual, approval/protocol, and lifecycle reviews reported zero
  Critical and zero Major source or fixture findings.

## Locked cold-launch observation

The exact installed release candidate was launched through LaunchServices while
the host was already at `loginwindow` with its main display online, inactive,
and asleep.

- LaunchServices type remained `UIElement`.
- Frontmost application ASN was unchanged.
- LaunchServices reported `visible = NULL`.
- No direct child process appeared.
- No `codex --enable realtime_conversation app-server --stdio` process
  appeared.
- Ten initial samples were 0.0% CPU with resident memory settling near 27 MB.
- At 2:04 dormant elapsed time the app measured 0.0% CPU and 18.6 MB RSS.
- The exact HUD PID terminated cleanly on `TERM`; frontmost application remained
  unchanged and no realtime child remained.

## Persistence and privacy observation

After the locked launch there was no Codex HUD application-support directory,
cache, log directory, WebKit store, HTTP store, or saved application state.
The only preference values were the allowed dedicated Voice Console thread
identifier and capability version. No audio or transcript artifact was found.

## User functional verification

The owner verified the installed app’s functionality on 2026-07-30 and accepted
this release candidate. The exhaustive timing, multi-display, and 15-minute
regression procedure remains documented in `QA/RELEASE_ACCEPTANCE.md` for future
tagged releases.
