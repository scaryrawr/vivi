# Streaming chat

Streaming chat proves that the compiled Vivi launcher starts a real Copilot CLI
prompt in a PTY with inherited terminal I/O and streamed output.

## Sub-features

- `prompt-entry` sends a prompt through Copilot's prompt mode.
- `streaming-response` returns a deterministic marker.
- `extension-materialization` installs all Vivi extensions before startup.
- `clean-exit` returns Copilot's successful exit status.

## How to get to it (user POV)

- Run `vivi` or `vivi --model <model-id>`.
- Or pass `-p <prompt>` for one-shot prompt mode.

## Driving it with verify-vivi

- Run `.github/skills/verify-vivi/bin/verify-vivi chat-streaming <run-id>`.
- Retain `chat-streaming.terminal.log` and
  `chat-streaming.assertions.txt`.

## Gotchas

- The submitted prompt contains `vivi_stream_ok`; the assertion requires the
  distinct uppercase `VIVI_STREAM_OK`.
- Authentication and service failures are precondition failures.
- The helper removes its isolated Copilot profile after the drive.
