# Native session history

Vivi exposes persisted sessions as a secondary, selected-conversation history
section while keeping live conversations as the primary native sidebar
navigation.

## Sub-features

- History is collapsed by default below the live conversation roster.
- Expanding History loads sessions saved by Vivi without changing the active
  transcript.
- The scope menu switches between Saved Vivi Sessions, grouped by workspace,
  and Copilot Sessions in This Workspace.
- Loading, failure with retry, empty, partially readable, and resuming states
  remain inline in the history section.
- Persisted rows are visually and accessibly distinct from live conversation
  rows, and only the requested row shows resume progress.
- A successful cross-workspace resume keeps the live conversation identity and
  selection while atomically updating its title, workspace, transcript, model,
  native window title, and duplicate-workspace position.
- Starting another `vivi chat --native` remains occurrence-based and creates a
  new live conversation rather than resuming history.

## How to get to it (user POV)

Build Vivi and run `./zig-out/bin/vivi chat --native` from a workspace that has
earlier Vivi sessions. Expand History in the sidebar, switch between Saved Vivi
Sessions and Copilot Sessions in This Workspace, and select a persisted
session. Repeat with another live conversation open from the resumed session's
workspace so the duplicate-workspace badges can update.

## Driving it with verify-vivi

Run the doctor, build once, and launch only through the worktree's
`./zig-out/bin/vivi chat --native`. Record the native window while expanding
History, switching both scopes, resuming a saved Vivi session from another
workspace, and selecting both resulting duplicate-workspace rows. Attempt a
second click while resume is pending, close and reopen the window through the
Dock, then quit. Retain the video and representative screenshots alongside the
exact Xcode and repository check output.

The PTY recipes do not control AppKit. They establish Copilot authentication
and can create resumable session data, but native interaction and native media
must be captured through the actual app.

## Gotchas

- Do not open a bare `vivi://` URL; another worktree's bundle may receive it.
- History always belongs to the selected `NativeChatStore`; switching live
  rows can show a different catalog or control state.
- Current catalog rows are not offered as resumable history.
- Catalog keys are opaque and generation-scoped. Refreshing invalidates the
  prior visible rows; do not manufacture or retain keys outside the store.
- Resume failure must preserve the current presentation and visible catalog.
- If local serializer data or Launch Services routing blocks the flow, capture
  the exact command and observed bundle/session artifacts instead of claiming
  native verification.
