# Vivi

Vivi is a small cross-platform launcher for an opinionated GitHub Copilot CLI
environment. It discovers local models before Copilot starts, installs bundled
extensions into an isolated profile, and then delegates the full interactive
experience to the upstream `copilot` executable.

## Requirements

- GitHub Copilot CLI available as `copilot`
- Bun 1.4.x for development only

Release binaries include the Bun runtime.

## Usage

```sh
vivi
vivi chat
vivi --model copilot/gpt-5.6-luna --reasoning high
vivi --model omlx/Qwen3.5-9B
vivi models
```

Running `vivi` with no command launches Copilot. `chat` is a compatibility
alias. All unrecognized arguments pass directly to Copilot CLI. Vivi also
translates its former `copilot/<model>` identifiers and `--reasoning` flag to
Copilot's native syntax.

Vivi loads the last model and reasoning selection from
`~/.vivi/settings.json`. Explicit `--model` or `--reasoning` arguments win.
Changing the model or reasoning effort through Copilot's `/model` flow updates
the Vivi setting for the next new session. Resumed sessions retain their own
saved model configuration.

Copilot's BYOK model registry does not currently expose supported reasoning
levels to the built-in model picker. For local models, use `/reasoning` to show
the current effort or `/reasoning high` to change it. The launcher flags
`--reasoning` and `--reasoning-effort` remain available for startup selection.

Vivi stores its persistent Copilot profile under `~/.vivi/copilot`. This keeps
Vivi sessions, permissions, plugins, and authentication separate from a normal
`~/.copilot` installation. Set `VIVI_HOME` to move the entire Vivi profile or
`VIVI_COPILOT_PATH` to select a specific Copilot executable.

## Local models

Before every launch, Vivi concurrently probes:

| Provider  | Default endpoint         |
| --------- | ------------------------ |
| Ollama    | `http://localhost:11434` |
| LM Studio | `http://localhost:1234`  |
| OMLX      | `http://localhost:8000`  |
| OSaurus   | `http://localhost:1337`  |
| GenieX    | `http://127.0.0.1:18181` |

Use `<PROVIDER>_BASE_URL`, `<PROVIDER>_API_KEY`, and the supported
`<PROVIDER>_CONTEXT_LENGTH` variables to override discovery. Unavailable
servers are ignored. The generated provider registry is private,
process-scoped, and removed after Copilot exits.

## Bundled extensions

Vivi enables Copilot's experimental extension runtime automatically because
current Copilot CLI releases gate extension discovery behind `--experimental`.

- `vivi-system-prompt` applies Vivi's compact coding-agent policy while
  preserving safety, environment, repository, and runtime instructions.
- `vivi-basic-tools` replaces overlapping Copilot built-ins with Vivi's
  `read`, `bash`, `edit`, and `write` implementations.
- `vivi-local-model-policy` blocks subagent and factory orchestration while a
  discovered local model is selected by declaring built-in exclusions when the
  extension joins the session.
- `vivi-reasoning` provides the `/reasoning` session command for local models.
- `vivi-selection-persistence` records model and reasoning changes for the next
  Vivi session.

## Development

```sh
bun install
bun run check
bun run build
./dist/vivi --help
```

Architecture and ownership decisions are documented in
[`docs/architecture.md`](docs/architecture.md).
