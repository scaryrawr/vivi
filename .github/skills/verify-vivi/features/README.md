# Vivi verification map

This directory is the maintained source for verifying Vivi's user-facing CLI
and libvaxis chat behavior. Read this index before driving the application,
then use the matching feature file as the recipe.

## Baseline preconditions

- Build from the repository root with `zig build`.
- Put Zig 0.16.x, VHS, `script`, and GitHub Copilot CLI on `PATH`.
- Authenticate GitHub Copilot CLI before driving `vivi chat`.
- Run `.github/skills/verify-vivi/bin/verify-vivi doctor`.
- Give every verification attempt a unique run ID. Evidence belongs in
  `.verify/vivi/<run-id>/`.
- Never drive a TUI that was started in the user's existing terminal session.

## Driving conventions

- Start each TUI drive in its own VHS or `script` PTY.
- Use literal command names, header text, transcript labels, and key chords
  from these recipes.
- Use Ctrl-C once for normal shutdown and a second time only after the UI shows
  `Stopping...`.
- Multiple instances may run concurrently only in separate PTYs and run
  directories. They still share the user's Copilot credential store.
- Do not replace the Copilot service with a mock for end-to-end claims.

## Proof and skip reporting

- Capture the typed action and the resulting screen.
- TUI proof requires extracted frames, a contact sheet, a completed
  visual-review checklist, a raw PTY transcript, and normalized terminal text
  for stable assertions. GIF retention is optional and does not strengthen the
  proof.
- Noninteractive CLI proof requires stdout, stderr, and exit status.
- A streaming proof must assert a response token that was not present in the
  submitted prompt.
- Preserve proof artifacts after cleanup.
- Reject a captured session with clipped headers, broken borders, overlapping
  regions, stale text, redraw corruption, or missing expected states even when
  text assertions pass.
- Report authentication, network, or Copilot service failures as unmet
  preconditions rather than as verified application behavior.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the
user-visible behavior. It then uses exactly four H2 sections in this order:

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with verify-vivi`
4. `Gotchas`

## Features

- [CLI discovery](./cli-discovery.md) covers help, version, and chat command
  discoverability.
- [Streaming chat](./streaming-chat.md) covers composer input, submission,
  streamed Copilot output, steering, queued follow-ups, and return to the
  ready state.
- [Ask-user prompt](./ask-user.md) covers interactive questions, numbered
  choices, answer entry, and resumed streaming.
- [Chat shutdown](./chat-shutdown.md) covers cooperative Ctrl-C shutdown and
  the explicit second-Ctrl-C escape path.
- [OMLX models](./omlx-models.md) covers live model discovery, token-limit
  detection, and an OMLX-backed chat session.
- [Slash model menu](./slash-model-menu.md) covers slash completion, the model
  picker, explicit hosted/local switching, and transcript/history behavior.
