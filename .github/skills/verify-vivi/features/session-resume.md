# Session resume

Vivi lets the user continue Copilot CLI sessions from its private Copilot home
through a filterable `/resume` finder.

## Sub-features

- Successful Vivi session creation is persisted by Copilot CLI under
  `~/.vivi/copilot/`.
- `/resume` lists saved sessions across workspaces without exposing Copilot
  session IDs.
- Resume rows show the session title and working directory without model
  metadata.
- The finder explains when no earlier session is available or a filter has no
  matches.
- Selecting a row resumes the saved Copilot session and replaces the visible Vivi
  transcript with persisted Copilot history before reporting success.
- A resumed session retains the server-side history from its earlier run.
- The active Vivi model and reasoning selection apply to the resumed session;
  Vivi does not maintain separate model metadata for saved sessions.
- Isolated verification homes do not modify the user's real Vivi settings or
  Copilot home.

## How to get to it (user POV)

Start `vivi chat`, use it normally, and exit. Start another chat, type
`/resume`, press Enter, select the saved workspace, and press Enter again. Use
the finder text to narrow sessions by title or working directory.

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
  both remain in the isolated private Copilot home.
- The resumed terminal transcript is hydrated from Copilot's persisted message
  history; a failed hydration leaves the current terminal transcript intact.
