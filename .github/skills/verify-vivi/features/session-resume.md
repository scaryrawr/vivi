# Session resume

Vivi records sessions it creates and lets the user continue their Copilot
history later through a filterable `/resume` finder.

## Sub-features

- Successful Vivi session creation writes durable metadata under
  `~/.vivi/sessions/`.
- `/resume` opens a private Vivi-session finder without exposing Copilot
  session IDs; `/resume all` searches Copilot sessions for the active workspace.
- The finder explains when no earlier session is available or a filter has no
  matches.
- Selecting a row joins the saved Copilot session and replaces the visible Vivi
  transcript with persisted Copilot history before reporting success.
- A resumed session retains the server-side history from its earlier run.
- Isolated verification homes do not modify the user's real Vivi settings or
  session index.

## How to get to it (user POV)

Start `vivi chat`, use it normally, and exit. Start another chat, type
`/resume`, press Enter, select the saved workspace, and press Enter again. Use
`/resume all` when the session was not previously recorded by Vivi but belongs
to the current workspace.

## Driving it with verify-vivi

```sh
.github/skills/verify-vivi/bin/verify-vivi chat-session-resume <run-id>
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-session-resume
```

The recipe starts one chat, asks it to transform a deterministic token, exits,
starts a second chat with the same isolated home, resumes the first session,
and asks for the transformed token.

## Gotchas

- Copilot authentication and service availability are required.
- The recipe deliberately creates a temporary second session before resuming;
  both remain in the isolated verification index.
- The resumed terminal transcript is hydrated from Copilot's persisted message
  history; a failed hydration leaves the current terminal transcript intact.
