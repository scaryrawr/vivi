# Native conversation sidebar

Vivi keeps independently running conversations in one native macOS window,
grouped by their remembered launch workspaces without transferring ownership
away from each conversation store.

## Sub-features

- An ordinary launch shows one empty native window.
- Every `vivi chat --native` occurrence adds and selects a fresh conversation,
  including repeated launches from the same workspace.
- Each canonical launch workspace gets one expandable project section for the
  app lifetime.
- Sidebar rows show the live conversation title and active workspace path;
  repeated workspaces receive stable numeric disambiguation.
- Selecting a row swaps the detail and native window title without stopping
  other conversations.
- Closing the window keeps conversation stores and drivers alive.
- Clicking Vivi in the Dock restores the same rows, selection, and conversation
  state.
- Quitting Vivi waits for every retained conversation to close.

## How to get to it (user POV)

Build Vivi, run `./zig-out/bin/vivi chat --native` from one workspace, then run
it again from another workspace and twice from the first. Select each sidebar
row. Close the native window with its red close control, click Vivi in the
Dock, and finally quit the app.

## Driving it with verify-vivi

Build once with `zig build`, then launch only through the worktree's
`./zig-out/bin/vivi chat --native`; do not open a bare `vivi://` URL. Retain a
screen recording that shows the launch action and resulting native state for
distinct and repeated workspaces, row selection, red close, Dock reopen, and
quit. Pair the recording with the exact Xcode test command and
`./scripts/check.sh`; the terminal helper does not substitute for native app
interaction.

## Gotchas

- Multiple worktree app bundles share a production identifier, so Launch
  Services may route a bare URL to stale code.
- A repeated workspace must create another row and driver, not activate an
  existing row.
- A cross-workspace resume updates the active workspace but does not move the
  conversation out of its launch-workspace project section.
- Red close and application quit intentionally have different conversation
  lifetime effects.
- Persisted session discovery and resume have their own
  [native session history](./native-session-history.md) verification flow.
