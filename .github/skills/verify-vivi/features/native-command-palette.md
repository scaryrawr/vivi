# Native command palette

Vivi exposes the backend-owned command catalog in a lightweight palette above
the native composer without duplicating model or session-history workflows.

## Sub-features

- Typing `/`, pressing Command-K, or using the command button opens the palette.
- Rows show backend-owned names, descriptions, and Vivi, SDK, or extension
  source labels.
- Filtering, wrapped arrow-key navigation, Return, and Escape preserve the
  ordinary composer draft and selected attachments.
- Commands with arguments enter a bounded argument field before execution.
- Loading, discovery failure with retry, blocked execution, and running states
  remain inline.
- `/model` opens the existing model picker and `/resume` expands the existing
  History section.
- Ask-user, responding, model-switch, resume, close, and stale-generation
  transitions gate execution without manufacturing command identity in Swift.

## How to get to it (user POV)

Build Vivi and run `./zig-out/bin/vivi chat --native`. Select an idle
conversation, press Command-K, filter commands, and navigate with Up, Down,
Return, and Escape. Repeat by typing `/` at the start of the composer. Activate
`model` and `resume` to inspect their existing native surfaces, then exercise a
safe SDK or extension command with arguments when one is available.

## Driving it with verify-vivi

Run the doctor and the `chat-model-menu` and `chat-customization` PTY recipes
first to prove live built-in and extension discovery through the production
Copilot boundary. Launch the native app only through the worktree's
`./zig-out/bin/vivi chat --native`, then record the command button or
Command-K path, filtering and keyboard navigation, model/history routing,
argument entry, and preserved draft/attachments. Retain the raw and edited
video with the PTY frames and assertions.

## Gotchas

- Do not open a bare `vivi://` URL; Launch Services can route it to another
  worktree's bundle.
- Command keys are opaque and generation-scoped. Refresh, model switch, and
  resume invalidate prior keys.
- Browsing a cached catalog may remain visible while execution is blocked.
- A command that becomes an assistant turn or ask-user request continues
  through the existing transcript reducer rather than a palette-specific flow.
- If the host cannot safely activate the background app for recording, retain
  the exact activation-policy error and do not claim native visual verification.
