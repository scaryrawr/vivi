# Repository Guidelines

## Project Structure

Vivi is a Bun monorepo that prepares an opinionated GitHub Copilot CLI profile
and launches the upstream `copilot` executable.

- `apps/vivi/` owns command parsing and process launching.
- `packages/provider-discovery/` discovers supported local model servers and
  emits Copilot's named provider/model registry.
- `packages/copilot-profile/` materializes Vivi-owned extensions and secure
  per-process configuration.
- `packages/settings/` parses, migrates, and writes Vivi's versioned default
  model and reasoning selection.
- `extensions/` contains independent TypeScript Copilot CLI extensions;
  `scripts/build-extensions.ts` bundles them before the launcher build.
- `scripts/build.ts` compiles the standalone cross-platform executable.

Copilot CLI owns the terminal UI, authentication, permissions, sessions,
tools, MCP integration, and conversation lifecycle. Do not reimplement those
surfaces in Vivi.

## Build and Test

Use Bun 1.4.x.

```sh
bun install
bun run build
bun run check
./scripts/check.sh
```

Default tests must not require Copilot credentials or a running Copilot CLI.
End-to-end verification uses the installed `copilot` executable and an
isolated `VIVI_HOME`.

## Style

Run `bun run format`. Preserve lowercase `vivi` for the executable and
capitalized `Vivi` for the product name. Keep provider discovery side-effect
free except for bounded HTTP requests. Extension stdout is reserved for the
Copilot JSON-RPC connection; use `session.log()` for user-visible messages.

## Profile Ownership

Within `COPILOT_HOME`, Vivi may overwrite only its named extension directories
and ephemeral runtime files. Never overwrite Copilot-managed authentication,
permission, plugin, session, history, or log state. Provider registries
containing API keys must be private, process-scoped, and removed after Copilot
exits. Version every `~/.vivi/settings.json` schema change, parse older
versions explicitly, migrate them in memory, and test the next write.

## Pull Requests

Keep changes narrowly scoped and include relevant command output in PR
descriptions. User-visible launcher or extension changes require evidence
captured through the compiled `dist/vivi` executable. Never commit generated
executables, caches, credentials, or runtime provider registries.
