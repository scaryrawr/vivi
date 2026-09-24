# Architecture

## Shape

Vivi is a Bun monorepo and standalone compiled launcher. It does not implement
an agent runtime or terminal UI. GitHub Copilot CLI is the product runtime.

`apps/vivi` parses Vivi-owned commands, discovers local providers,
prepares the profile, and starts `copilot` with inherited stdio.

`packages/provider-discovery` contains provider-specific HTTP adapters. Its
output is a structural match for Copilot's named `providers` and `models`
registry.

`packages/copilot-profile` owns filesystem reconciliation. It may write only:

- Vivi's named directories under `<COPILOT_HOME>/extensions/`.
- A private, process-scoped `providers.json`.

The provider registry is removed when the child process exits. Later launches
also reap abandoned runtime directories after confirming that both the Vivi
launcher and tracked Copilot child are gone. Copilot owns every other file in
its home.

`packages/settings` owns `~/.vivi/settings.json`. Version 3 stores the default
model plus an optional reasoning-effort override. Versions 1 and 2 are parsed
explicitly and rewritten as version 3 on the next launch.

## Startup boundary

Model discovery happens before Copilot starts so local models are present in
the initial model picker. The launcher sets:

- `COPILOT_HOME` to `<VIVI_HOME>/copilot`.
- `COPILOT_PROVIDERS_CONFIG` to the process-scoped registry.
- `VIVI_SETTINGS_PATH` for selection persistence.

Unavailable providers do not block startup. Discovery has a three-second
timeout per provider and runs concurrently.

## Extension boundary

Extensions are TypeScript entrypoints in independent packages under
`extensions/`. `scripts/build-extensions.ts` bundles each entrypoint and its
package dependencies for Node into `dist/extensions/<name>/extension.mjs`,
leaving `@github/copilot-sdk/extension` external for Copilot's extension
runtime. The launcher build embeds those outputs as text assets. At startup,
Vivi reconciles each bundled file into its own Copilot extension directory and
enables Copilot's experimental extension runtime. An explicit
`--no-experimental` is rejected because it would silently disable Vivi's
bundled behavior. TypeScript checks the sources, not the generated files.

The system prompt extension replaces the preamble, removes inherited identity,
tone, efficiency, code-change, guideline, safety, and tool-instruction sections,
and retains the dynamic working-directory context, repository, and runtime
instructions. Copilot supplies its built-in tool descriptions and parameter
schemas independently of the system prompt.
It also excludes subagent and factory orchestration for every model at
`joinSession()`, without model detection. Vivi does not replace Copilot's
built-in file or shell tools. It excludes unrelated Copilot built-ins with
`builtin:`-qualified names, without restricting external extensions or MCP
tools. Copilot's tool-search tools remain available to discover them.
Extensions do not perform provider discovery because `joinSession()` occurs
after the initial session model registry is created. On launch, Vivi removes
the previous model-specific policy and basic-tools entrypoints from existing
profiles. The selection persistence extension records model and reasoning
changes in the versioned Vivi settings document. The reasoning extension
supplies `/reasoning` because Copilot's BYOK provider schema cannot publish
the supported-effort list required by the built-in model picker.

## Process boundary

Arguments not owned by Vivi pass directly to Copilot. The launcher inherits
stdin, stdout, and stderr and returns Copilot's exit status. Legacy CLI
aliases and flag translations are not supported; saved settings from earlier
versions still migrate to native Copilot model IDs.

For new sessions, the launcher supplies the persisted model and reasoning
selection unless explicit arguments override them. Resume and connect commands
retain the saved session's own model configuration.

## Verification

`bun run check` covers formatting, linting, type checking, unit tests, and the
standalone build without credentials. End-to-end verification drives
`dist/vivi` with the real Copilot CLI and an isolated `VIVI_HOME`.
