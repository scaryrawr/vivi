# Native project entry

Vivi starts fresh native conversations from directory choices and groups every
live conversation under its current canonical workspace without adding another
project catalog.

## Sub-features

- The sidebar, empty state, and File > New Conversation (Command-N) open the
  same native directory chooser.
- Choosing a directory creates and selects a fresh conversation even when that
  workspace already has live conversations.
- Cancelling the chooser leaves the roster and selection unchanged.
- Invalid, missing, or non-directory selections show an app-shell alert without
  adding transcript content or silently choosing another workspace.
- Project headers remain visible with one project, show the canonical workspace,
  and contain live conversation-title children with workspace-local ordinals.
- Cross-workspace resume moves the existing conversation to its new project and
  recomputes ordinals without changing its conversation identity.

## How to get to it (user POV)

Build Vivi and launch `./zig-out/bin/vivi chat --native`. Use the empty-state
button or Command-N to choose a workspace, then use New Conversation again for
the same workspace and for a different workspace. Cancel one chooser. Resume a
saved session whose workspace differs from its current project.

## Driving it with verify-vivi

Run the doctor, build once, and launch only through the worktree's
`./zig-out/bin/vivi chat --native`. Record the native app while exercising the
empty-state action, chooser cancellation, duplicate workspace creation,
multiple project sections, Command-N, and cross-workspace resume regrouping.
Close the window with its red control, restore it from the Dock, confirm the
same project hierarchy remains, and quit. Retain the native recording and
representative screenshots with the exact Xcode and repository check output.

The PTY recipes cannot control AppKit. They establish authentication and may
prepare resumable sessions, but the directory chooser and native hierarchy must
be driven and captured through the actual application.

## Gotchas

- Do not open a bare `vivi://` URL; another worktree's bundle may receive it.
- A duplicate directory choice creates another independent conversation rather
  than selecting the existing one.
- History remains scoped to the selected conversation, not to its project
  section.
- Chooser cancellation is not an error. Quit while the chooser is open must not
  admit a late conversation.
- If local serializer data or the computer-use serializer blocks capture,
  preserve the exact failure and do not claim native visual verification.
