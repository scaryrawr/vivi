# CLI discovery

CLI discovery lets a user inspect Vivi and discover its launcher commands
without starting Copilot.

## Sub-features

- `help-explicit` shows the command list with `--help`.
- `version` prints the installed Vivi version.
- `models-listed` reports discovered local providers.
- `native-args` leaves Copilot options and commands unchanged.

## How to get to it (user POV)

- Run `vivi` to launch Copilot, or `vivi --help` to see Vivi commands.
- Run `vivi --version`.
- Run `vivi models`.

## Driving it with verify-vivi

- Ensure `bun run build` succeeds.
- Run `.github/skills/verify-vivi/bin/verify-vivi cli-discovery <run-id>`.
- Retain `help.stdout`, `help.stderr`, `version.stdout`, `version.stderr`,
  `models.stdout`, `models.stderr`, and `cli-discovery.assertions.txt`.

## Gotchas

- Local model discovery does not require Copilot authentication.
- Use the compiled binary from `dist/vivi`.
- An empty stderr is expected on success but is not sufficient proof by itself.
