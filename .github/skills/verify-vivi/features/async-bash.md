# Async Bash

Vivi can start a Bash command under a real PTY without keeping an SDK tool call
open, then list, read, write to, and stop that shell from later finite calls.
Synchronous `bash` remains the default.

## Sub-features

- `bash` action `start` returns an opaque `bash_…` shell ID.
- `bash` action `write` accepts later UTF-8 or base64 input.
- `bash` action `read` returns bounded, consuming output after a bounded wait.
- `bash` action `list` reports running/exited state and unread/dropped counts.
- `bash` action `stop` terminates and reaps the shell's POSIX process group or
  Windows job and is safe to repeat.
- Tool activity distinguishes starting, listing, reading, writing, and
  stopping Bash sessions.

## How to get to it (user POV)

Run `vivi chat` and ask Vivi to start an interactive command asynchronously,
send it input, read its output, list the shell, and stop it. The transcript
should show each finite tool operation and finish back at `Ready`.

## Driving it with verify-vivi

```sh
.github/skills/verify-vivi/bin/verify-vivi doctor
VIVI_KEEP_GIF=1 \
  .github/skills/verify-vivi/bin/verify-vivi chat-async-bash <run-id>
```

The recipe defaults to `VIVI_VALIDATION_MODEL`, which is
`copilot/gpt-5.6-luna` unless overridden. Set `VIVI_ASYNC_BASH_MODEL` to
exercise a specific hosted or OMLX model.

Inspect the contact sheet and frames, complete the generated visual review,
then run:

```sh
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-async-bash
```

The normalized transcript must contain `VIVI_ASYNC_BASH_OK`. The raw terminal
log must show Start Bash, List Bash sessions, Write Bash, Read Bash, and Stop
Bash activity.

## Gotchas

- The model chooses tools, so a service-side refusal or model deviation is a
  failed live verification, not permission to replace the drive with a mock.
- PTY output can include terminal control sequences. Stable text assertions
  use the normalized transcript; visual review still uses extracted frames.
- Cross-builds establish compilation only. Native PTY behavior must be driven
  on each claimed host.
- Use the first Ctrl-C for cooperative Vivi shutdown. The second is only the
  documented forced-exit path.
