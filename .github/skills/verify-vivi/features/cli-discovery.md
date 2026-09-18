# CLI discovery

CLI discovery lets a user inspect Vivi's version and find the interactive chat
command without starting Copilot.

## Sub-features

- `chat-default` starts the chat when Vivi has no arguments (same as
  `vivi chat`; chat flags like `--model` work without the `chat` word).
- `help-explicit` shows the command list with `--help`.
- `version` prints the installed Vivi version.
- `models-listed` identifies model discovery, token-limit reporting, and
  selectable reasoning levels.
- `chat-listed` identifies `chat` as an interactive streaming command.

## How to get to it (user POV)

- Run `vivi` to enter chat directly, or `vivi --help` to see the command list.
- Run `vivi --version`.
- Run `vivi models`.

## Driving it with verify-vivi

Preconditions:

- `zig build` succeeds.
- A unique run ID is available.

- **Capture discovery output.** Run
  `.github/skills/verify-vivi/bin/verify-vivi cli-discovery <run-id>`.
  `help.stdout` contains
  `models     List available Copilot and OMLX models.` and
  `chat       Start an interactive streaming Vivi chat.`, `version.stdout`
  starts with `vivi `, `models.stdout` includes tab-separated `reasoning=` and
  `default=` fields, and all three exit statuses are `0`.
- **Proof.** Retain `help.stdout`, `help.stderr`, `version.stdout`,
  `version.stderr`, `models.stdout`, `models.stderr`, and
  `cli-discovery.assertions.txt` under the run directory.

## Gotchas

- Model discovery requires Copilot authentication but does not prove terminal
  rendering.
- Use the built binary from `zig-out/bin/vivi`; `zig build run` adds build
  runner behavior to the observed command.
- An empty stderr is expected on success but is not sufficient proof by itself.
