---
name: verify-vivi
description: Verify the Vivi CLI and libvaxis chat TUI through real PTY sessions, streamed Copilot responses, and durable terminal evidence. Use when changing CLI commands, terminal input/rendering, conversation lifecycle, or Copilot streaming.
---

# Verify Vivi

Drive the installed `vivi` executable as a user would. Do not call backend
functions directly as proof of CLI or TUI behavior.

## Launch

Build the executable once from the repository root:

```sh
zig build
```

Vivi is a short-lived CLI/TUI, not a server. Start every interactive drive in
its own `script` PTY:

```sh
.github/skills/verify-vivi/bin/verify-vivi chat-streaming <run-id>
```

The TUI is ready when the captured frames show the `vivi` welcome, `Ready`
context, and the bottom composer with its colored left accent. The helper
submits a deterministic prompt, waits for the streamed answer, and sends
Ctrl-C to shut down. asciinema is only the recording mechanism and `agg`
renders its GIF; the GIF is deleted after frame extraction by default. `script`
and asciinema own their child processes, so no persistent instance remains
after the helper returns.

Credentialed hosted-Copilot validation defaults to
`copilot/gpt-5.6-luna`. Set `VIVI_VALIDATION_MODEL` to another
`copilot/<model-id>` only when a validation requirement explicitly calls for
it. The helper validates and shell-quotes that value before use. Specialized
attachment and async-Bash overrides still permit an explicit hosted or OMLX
model because model capability can be part of those tests. Credential-free
unit, build, and offline checks are unaffected. Recipes that explicitly test
bare or implicit invocation, model discovery, model switching, or OMLX keep
the model behavior required by that feature.

If a manual drive is required, run `./zig-out/bin/vivi chat` in a fresh
terminal. Press Ctrl-C once for cooperative shutdown. Press Ctrl-C a second
time only when the UI is still showing `Stopping...`.

## Doctor

Run this health check before any drive when the environment or authentication
looks questionable:

```sh
.github/skills/verify-vivi/bin/verify-vivi doctor
```

It requires Zig, asciinema, `agg`, `script`, Expect, FFmpeg/FFprobe, GitHub
CLI with an available `gh auth token`, and GitHub Copilot CLI; builds Vivi;
checks the installed Vivi, asciinema, `agg`, and Copilot versions; records a
temporary asciinema session and renders it with `agg` as a smoke GIF; and
sends a no-tools Copilot prompt that must return `VIVI_DOCTOR_OK`. A failure
means the instance is not worth driving. Set `VIVI_ASCIINEMA` or `VIVI_AGG`
to point at non-default binary locations. Copilot CLI
does not expose a standalone authenticated status command, so the minimal
prompt is the authentication check.

## Drive

Use the executable helper:

```sh
.github/skills/verify-vivi/bin/verify-vivi cli-discovery <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-streaming <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-streaming-input <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-default <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-implicit <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-attachments <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-async-bash <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-markdown <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-markdown-read <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-ask-user <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-file-picker <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-model-menu <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-customization <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-session-resume <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-shutdown <run-id>
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-markdown
```

`chat-default` launches bare `vivi` and proves that it enters chat.
`chat-implicit` launches a chat flag without the `chat` subcommand and proves
that the selected model display name reaches the TUI. Both drives retain the
same PTY transcript, normalized text, assertions, frames, contact sheet, and
visual-review evidence as `chat-streaming`, and both names are accepted by
`extract-frames` and `frame-check`.

`<run-id>` must contain only letters, digits, dots, underscores, or hyphens.
Each command writes to `.verify/vivi/<run-id>/`, so concurrent runs do not
share PTYs or evidence. Multiple Vivi processes may run side by side because
each owns its own Copilot child and session, but they share the user's Copilot
credential store. Never automate two instances against the same terminal.

Recipes that replace `HOME` must pass an authenticated `gh auth token` through
`GH_TOKEN` and `GITHUB_TOKEN`. Do not symlink the user's `~/.copilot` directory:
Vivi sets Copilot's process home to `$HOME/.vivi/copilot`, so that symlink
neither authenticates the isolated process nor preserves plugin/session
isolation.

The stable user handles are:

- `vivi --help` and `vivi --version` for command discovery.
- The context state `Ready` for an idle chat.
- The context state `Responding...` while a turn streams.
- Transcript labels `You` and `Vivi`.
- The message `Stopping... press Ctrl-C again to force exit.` after the first
  Ctrl-C.

Read the feature map before choosing a drive:

```sh
cat .github/skills/verify-vivi/features/README.md
```

## Evidence

Evidence lives under `.verify/vivi/<run-id>/` and is intentionally ignored by
Git. Keep it after cleanup.

For TUI proof, capture:

- `*.contact-sheet.png`: two-second samples across the full captured session.
- `*.frames/frame-*.png`: one frame per second for detailed inspection.
- `*.frames.txt`: capture dimensions, duration, and extracted frame count.
- `*.visual-review.md`: explicit appearance and state-transition checklist.
- `*.terminal.log`: raw PTY transcript for machine-readable assertions.
- `*.normalized.txt`: the same PTY output with terminal control sequences
  removed for stable text assertions.
- `*.assertions.txt`: the exact expected marker and command exit status.
- `*.cast`: the asciicast recording captured during the run (kept only with
  `VIVI_KEEP_GIF=1`).

The GIF is not proof. It is an optional presentation artifact for demos or PR
descriptions. Set `VIVI_KEEP_GIF=1` when running a TUI recipe to retain it:

```sh
VIVI_KEEP_GIF=1 \
  .github/skills/verify-vivi/bin/verify-vivi chat-streaming <run-id>
```

Set `VIVI_SKIP_RECORDING=1` only when asciinema or `agg` is unavailable and
terminal-only diagnosis is still useful. Every TUI recipe then launches Vivi
directly inside `script`, skips rendering, and writes a `*.visual-blocker.txt`
note alongside the terminal transcript, normalized text, and assertions.
This mode does not produce valid visual proof.

For noninteractive CLI proof, capture stdout, stderr, and exit status in
separate files.

A valid proof exercises `./zig-out/bin/vivi`, not a backend test seam. Capture
the action and the resulting state, not only the final frame. For streaming,
the expected answer marker must not occur in the submitted prompt; the helper
asks Copilot to transform `vivi_stream_ok` and asserts the distinct
`VIVI_STREAM_OK` response.

After every TUI drive, open the contact sheet and enough individual frames to
check each line in `*.visual-review.md`. Record the frame numbers and concrete
observations, replace every `[ ]` with `[x]` for a pass or `[!]` for a failure,
and set `status: pass` or `status: fail`. Then run:

```sh
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> <capture>
```

The authoritative visual proof is the extracted frame set plus a completed
review accepted by `frame-check`. Normalized terminal text separately proves
the expected content. Appearance review must cover readability, borders,
overlap, stale content, redraw corruption, and the expected state sequence.

The Copilot service is the production boundary for this feature. Do not replace
it with a mock when claiming end-to-end chat verification. Credential-free
unit tests remain useful but prove a different layer.

## Cleanup

The helper sends the application's documented shutdown keys and waits for the
PTY owner it started. Its exit trap kills only that recorded PID if a failed
run leaves it alive. It never kills by process name.

Run cleanup explicitly after an interrupted attempt:

```sh
.github/skills/verify-vivi/bin/verify-vivi cleanup <run-id>
```

Cleanup removes only transient PID files and empty generated files from an
unfinished run. It preserves casts, extracted frames, contact sheets, visual
reviews, terminal transcripts, normalized text, assertions, stdout, stderr, and
any GIF explicitly retained with `VIVI_KEEP_GIF=1`.
After cleanup, confirm the evidence directory still exists:

```sh
test -d ".verify/vivi/<run-id>"
```

## Helpers

`.github/skills/verify-vivi/bin/verify-vivi` is the only helper. It is
executable and accepts:

```text
doctor
cli-discovery <run-id>
chat-streaming <run-id>
chat-streaming-input <run-id>
chat-default <run-id>
chat-implicit <run-id>
chat-markdown <run-id>
chat-markdown-read <run-id>
chat-ask-user <run-id>
chat-file-picker <run-id>
chat-model-menu <run-id>
chat-customization <run-id>
chat-session-resume <run-id>
chat-shutdown <run-id>
extract-frames <run-id> <chat-streaming|chat-streaming-input|chat-default|chat-implicit|chat-attachments|chat-async-bash|chat-markdown|chat-markdown-read|chat-ask-user|chat-file-picker|chat-model-menu|chat-customization|chat-session-resume|chat-shutdown>
frame-check <run-id> <chat-streaming|chat-streaming-input|chat-default|chat-implicit|chat-attachments|chat-async-bash|chat-markdown|chat-markdown-read|chat-ask-user|chat-file-picker|chat-model-menu|chat-customization|chat-session-resume|chat-shutdown>
cleanup <run-id>
```

Run it from anywhere inside the repository. It resolves the repository root
with Git, builds the existing Zig target, and never installs dependencies.
