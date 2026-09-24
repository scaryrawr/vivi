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
vivi --model gpt-5.6-luna --reasoning-effort high
vivi --model omlx/Qwen3.5-9B
vivi models
```

Running `vivi` with no command launches Copilot. Apart from Vivi's `models`,
`--help`, and `--version`, arguments pass directly to Copilot CLI. Use
`copilot --help` to see its native options and commands.

Vivi loads the last model and reasoning selection from
`~/.vivi/settings.json`. Explicit `--model` or `--reasoning-effort` arguments win.
Changing the model or reasoning effort through Copilot's `/model` flow updates
the Vivi setting for the next new session. Resumed sessions retain their own
saved model configuration. Earlier Vivi settings are migrated to the current
schema, including hosted model IDs saved with a `copilot/` prefix.

Copilot's BYOK model registry does not currently expose supported reasoning
levels to the built-in model picker. For local models, use `/reasoning` to show
the current effort or `/reasoning high` to change it. The launcher flags
`--reasoning-effort` remains available for startup selection.

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
The extensions are authored in TypeScript and compiled into self-contained
`extension.mjs` files before building Vivi. Their package dependencies are
bundled into those files; only Copilot's extension SDK remains a runtime import.

- `vivi-system-prompt` applies Vivi's compact coding-agent policy and excludes
  subagent and factory orchestration for every model. It retains repository and
  runtime instructions but removes other inherited prompt sections.
- `vivi-basic-tools` replaces overlapping Copilot built-ins with Vivi's
  `read`, `bash`, `edit`, and `write` implementations. Their JSON Schema tool
  parameters are defined with TypeBox. `read` runs without a permission prompt;
  the other tools retain Copilot's permission flow.
- `vivi-reasoning` provides the `/reasoning` session command for models whose
  supported effort levels are not exposed by Copilot's model picker.
- `vivi-selection-persistence` records model and reasoning changes for the next
  Vivi session.

## Development

```sh
bun install
bun run check
bun run build
./dist/vivi --help
```

`bun run build` builds the extensions first, then embeds them in the compiled
launcher. `bun run test` builds the extensions before running tests, including
profile materialization tests. Generated files under `dist/` are not committed.

Architecture and ownership decisions are documented in
[`docs/architecture.md`](docs/architecture.md).
