# Release Acceptance Protocol

Automated gates are necessary but insufficient. Run this protocol on the target
M1 MacBook Air after `./script/quality_gate.sh` passes.

## Preconditions

- Official Codex is installed, signed by OpenAI Team ID `2DC432GLL2`, and
  authenticated with the user’s subscription.
- A single dedicated task named `Voice Console` exists or can be restored.
- Codex HUD has Microphone permission. Accessibility may be granted for the
  optional Open Voice Console convenience action but is not required for voice.
- Screen Recording permission is absent.
- The exact runnable build is `~/Applications/CodexHUD.app`.
- The matching portable artifact is `dist/CodexHUD.app.zip`; the automated gate
  must extract it, verify its signature, and match its executable and Info.plist
  to the installed build.

## Fifteen-minute acceptance session

Record start/end wall time and keep the previously focused app visible.

1. While the session is locked or the display is asleep, launch Codex HUD.
   Confirm there is no visible HUD, focus change, app-server child, WebRTC
   start, or microphone activity. Unlock and confirm the requested dormant orb
   appears only after the session and display are verified active.
2. Confirm Codex HUD is a menu-bar accessory with a dormant orb.
3. Press Shift-Option-Command-Space. Measure warm time to unmistakable listening;
   the limit is 500 ms.
4. Speak several short and long turns. Confirm the official Codex window never
   becomes visible and focus never leaves the original app.
5. Interrupt at least three spoken replies at different points. Each must stop
   speech and return to listening immediately.
6. Ask Voice Console to inspect another task.
7. Ask it to create or hand off a bounded task.
8. Trigger one externally visible or destructive proposal. Confirm nothing
   proceeds until the HUD shows explicit Approve and Reject actions.
9. Reject once, then repeat and approve once.
10. Trigger a long result and use Open in Codex. This explicit action is the only
   point at which the official Codex window may appear.
11. Hide the idle orb, restart a session by shortcut, and verify an active
    microphone remains visibly represented.
12. Kill the Codex app-server child process owned by Codex HUD while listening.
    Codex HUD must pause the microphone and show a precise recoverable error.
13. Repair the connection. Verify it starts a fresh app-server subprocess and
    restores the same Voice Console task.
14. Stop the session and confirm microphone activity and level immediately
    return to zero.
15. Continue until at least 15 minutes have elapsed.

## Focus evidence

Before each scenario record the frontmost application bundle identifier. Poll
it during transitions and after recovery. Any unexpected change is Critical.
Opening Codex via the explicit Open in Codex action is the sole allowed change.

## Resource evidence

Sample process CPU and resident memory:

- dormant after two minutes;
- listening after two minutes;
- speaking;
- immediately after stop;
- five minutes after stop.

Investigate sustained idle CPU above 1% or idle resident memory above 120 MB on
the target machine. These are investigation thresholds, not permission to
ignore a visible regression below them.

## Privacy evidence

- Inspect `~/Library/Application Support`, caches, logs, and preferences for
  Codex HUD before and after the session.
- No microphone recording or transcript archive may appear.
- Unified logs must not include spoken content.
- Confirm no OpenAI API key prompt or separate billing surface exists.
- Confirm System Settings shows no Screen Recording grant for Codex HUD.
- Confirm voice still works with Accessibility denied; only the explicit Open
  Voice Console convenience action may require it.

## Required result

Pass requires every automated check, every acceptance step, and the hostile
visual review to complete with zero Critical and zero Major findings.
