# CLI discovery

CLI discovery lets a user inspect Vivi's version and find the interactive chat
command without starting Copilot.

## Sub-features

- `help-default` shows help when Vivi has no arguments.
- `help-explicit` shows the same command list with `--help`.
- `version` prints the installed Vivi version.
- `chat-listed` identifies `chat` as an interactive streaming command.

## How to get to it (user POV)

- Run `vivi`.
- Run `vivi --help`.
- Run `vivi --version`.

## Driving it with verify-vivi

Preconditions:

- `zig build` succeeds.
- A unique run ID is available.

- **Capture discovery output.** Run
  `.github/skills/verify-vivi/bin/verify-vivi cli-discovery <run-id>`.
  `help.stdout` contains
  `chat       Start an interactive streaming Vivi chat.`, `version.stdout`
  starts with `vivi `, and both exit statuses are `0`.
- **Proof.** Retain `help.stdout`, `help.stderr`, `version.stdout`,
  `version.stderr`, and `cli-discovery.assertions.txt` under the run directory.

## Gotchas

- This feature does not prove Copilot authentication or terminal rendering.
- Use the built binary from `zig-out/bin/vivi`; `zig build run` adds build
  runner behavior to the observed command.
- An empty stderr is expected on success but is not sufficient proof by itself.
