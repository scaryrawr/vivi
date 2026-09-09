# Session resume

Vivi records sessions it creates and lets the user continue their Copilot
history later through a filterable `/resume` finder.

## Sub-features

- Successful Vivi session creation writes durable metadata under
  `~/.vivi/sessions/`.
- `/resume` opens a workspace-oriented finder without exposing Copilot session
  IDs.
- Selecting a row joins the saved Copilot session and preserves the visible
  Vivi transcript.
- A resumed session retains the server-side history from its earlier run.
- Isolated verification homes do not modify the user's real Vivi settings or
  session index.

## How to get to it (user POV)

Start `vivi chat`, use it normally, and exit. Start another chat, type
`/resume`, press Enter, select the saved workspace, and press Enter again.

## Driving it with verify-vivi

```sh
.github/skills/verify-vivi/bin/verify-vivi chat-session-resume <run-id>
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-session-resume
```

The recipe starts one chat, asks it to remember a deterministic token, exits,
starts a second chat with the same isolated home, resumes the first session,
and asks for the remembered token.

## Gotchas

- Copilot authentication and service availability are required.
- The recipe deliberately creates a temporary second session before resuming;
  both remain in the isolated verification index.
- The visible terminal transcript is local to each Vivi process even though
  Copilot history is resumed.
