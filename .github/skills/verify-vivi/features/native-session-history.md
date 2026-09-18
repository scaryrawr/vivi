# Native session history

Vivi groups live and persisted sessions beneath remembered launch-workspace
projects in the native sidebar.

## Sub-features

- Each canonical workspace launched during the app lifetime has one stable
  project section with its canonical path visible beneath the project name.
- Live conversation rows appear first in roster order, followed directly by
  resumable sessions in backend catalog order.
- Loading, failure with retry, empty, and resuming states remain inline in the
  project section.
- Persisted rows are visually and accessibly distinct from live conversation
  rows, and only the requested row shows resume progress.
- A successful cross-workspace resume keeps the live conversation identity and
  project section and selection while atomically updating its title, active
  workspace, transcript, toolbar conversation title, and duplicate-workspace
  position.
- Starting another `vivi chat --native` remains occurrence-based and creates a
  new live conversation rather than resuming history.

## How to get to it (user POV)

Build Vivi and run `./zig-out/bin/vivi chat --native` from a workspace that has
earlier sessions in Vivi's isolated Copilot SDK store at
`~/.vivi/copilot/`. Launch it again from another workspace and select a
persisted session directly beneath either project. Repeat with another live
conversation open from the resumed session's workspace so the
duplicate-workspace badges can update.

## Driving it with verify-vivi

Run the doctor, build once, and launch only through the worktree's
`./zig-out/bin/vivi chat --native`. Record the native window while resuming a
saved Vivi session beneath each of two projects and selecting both resulting
duplicate-workspace rows. Verify exactly one live or saved row is highlighted
at a time and selection does not reorder either project's roster. Attempt a
second click while resume is pending, close and reopen the window through the
Dock, then quit. Retain the video and representative screenshots alongside the
exact Xcode and repository check output.

The PTY recipes do not control AppKit. They establish Copilot authentication
and can create resumable session data, but native interaction and native media
must be captured through the actual app.

## Gotchas

- Do not open a bare `vivi://` URL; another worktree's bundle may receive it.
- A project's history uses one live `NativeChatStore` launched from that
  project; selecting a persisted row selects that live conversation before
  resuming.
- Remembered projects last for the app lifetime. This feature does not add a
  persisted project database or merge Git worktrees into repository identities.
- Current catalog rows are not offered as resumable history.
- The backend returns one cross-workspace catalog and copied canonical working
  directories. Swift groups those summaries without inspecting SDK storage.
- Catalog keys are opaque, store-bound, and generation-scoped. Refreshing
  invalidates the prior visible rows; do not manufacture, transfer, or retain
  keys outside the store.
- Resume failure must preserve the current presentation and visible catalog.
- If local serializer data or Launch Services routing blocks the flow, capture
  the exact command and observed bundle/session artifacts instead of claiming
  native verification.
