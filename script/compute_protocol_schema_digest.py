#!/usr/bin/env python3
"""Hash the exact transitive app-server schemas used by Codex HUD."""

from __future__ import annotations

import hashlib
import pathlib
import re
import sys


ROOTS = """
InitializeCapabilities.ts
InitializeParams.ts
InitializeResponse.ts
GetAuthStatusParams.ts
GetAuthStatusResponse.ts
ApplyPatchApprovalParams.ts
ApplyPatchApprovalResponse.ts
ExecCommandApprovalParams.ts
ExecCommandApprovalResponse.ts
v2/GetAccountParams.ts
v2/GetAccountResponse.ts
v2/AccountUpdatedNotification.ts
v2/AskForApproval.ts
v2/ApprovalsReviewer.ts
v2/SandboxMode.ts
v2/ThreadRealtimeStartParams.ts
v2/ThreadRealtimeStartResponse.ts
v2/ThreadRealtimeSdpNotification.ts
v2/ThreadRealtimeStartedNotification.ts
v2/ThreadRealtimeTranscriptDeltaNotification.ts
v2/ThreadRealtimeTranscriptDoneNotification.ts
v2/ThreadRealtimeErrorNotification.ts
v2/ThreadRealtimeClosedNotification.ts
v2/ThreadRealtimeStopParams.ts
v2/ThreadRealtimeStopResponse.ts
v2/CommandExecutionRequestApprovalParams.ts
v2/CommandExecutionRequestApprovalResponse.ts
v2/FileChangeRequestApprovalParams.ts
v2/FileChangeRequestApprovalResponse.ts
v2/PermissionsRequestApprovalParams.ts
v2/PermissionsRequestApprovalResponse.ts
v2/ServerRequestResolvedNotification.ts
v2/ItemStartedNotification.ts
v2/FileChangePatchUpdatedNotification.ts
v2/DynamicToolCallParams.ts
v2/DynamicToolCallResponse.ts
v2/ToolRequestUserInputParams.ts
v2/ToolRequestUserInputResponse.ts
v2/McpServerElicitationRequestParams.ts
v2/McpServerElicitationRequestResponse.ts
v2/CurrentTimeReadParams.ts
v2/CurrentTimeReadResponse.ts
v2/AttestationGenerateParams.ts
v2/AttestationGenerateResponse.ts
v2/ChatgptAuthTokensRefreshParams.ts
v2/ChatgptAuthTokensRefreshResponse.ts
v2/ThreadStartParams.ts
v2/ThreadStartResponse.ts
v2/ThreadResumeParams.ts
v2/ThreadResumeResponse.ts
v2/ThreadListParams.ts
v2/ThreadListResponse.ts
v2/ThreadReadParams.ts
v2/ThreadReadResponse.ts
v2/ThreadSetNameParams.ts
v2/ThreadSetNameResponse.ts
v2/TurnStartParams.ts
v2/TurnStartResponse.ts
v2/TurnInterruptParams.ts
v2/TurnInterruptResponse.ts
v2/TurnStartedNotification.ts
v2/TurnCompletedNotification.ts
""".split()

IMPORTS = re.compile(r"""from\s+["']([^"']+)["']""")


def main() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: compute_protocol_schema_digest.py SCHEMA_DIR")

    base = pathlib.Path(sys.argv[1]).resolve()
    seen: set[pathlib.Path] = set()
    stack = [base / root for root in ROOTS]
    while stack:
        path = stack.pop().resolve()
        if path in seen:
            continue
        if not path.is_file():
            raise SystemExit(
                f"missing schema dependency: {path.relative_to(base)}"
            )
        seen.add(path)
        source = path.read_text(encoding="utf-8")
        for relative in IMPORTS.findall(source):
            if relative.startswith("."):
                stack.append((path.parent / (relative + ".ts")).resolve())

    digest = hashlib.sha256()
    ordered = sorted(seen, key=lambda value: str(value.relative_to(base)))
    for path in ordered:
        relative = str(path.relative_to(base))
        digest.update(relative.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")

    print(f"{digest.hexdigest()} {len(ordered)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
