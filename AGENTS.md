# Repository Guidelines

## Project Structure

Vivi is a cross-platform CLI undergoing a controlled migration from Zig to
TypeScript and Bun. Zig remains the production implementation until the
TypeScript CLI passes the behavior-parity and release gates.

- `backend/src/root.zig` owns Copilot SDK adaptation and is the only production
  Zig module allowed to import `copilot_sdk`.
- `backend/src/` contains SDK-free domain services for conversations, tools,
  models, settings, presentation, file picking, attachments, and PTYs.
- `cli/src/` owns command parsing and the libvaxis terminal interface.
- `packages/core/` contains the framework-independent TypeScript domain model.
- `packages/copilot-adapter/` is the only TypeScript package allowed to import
  `@github/copilot-sdk`.
- `packages/frontend-opentui/` is the only TypeScript package allowed to import
  `@opentui/core`.
- `packages/testkit/` contains deterministic fakes and parity data types.
- `build.zig.zon` is the sole Zig SDK dependency pin.
- `package.json` and `bun.lock` pin the TypeScript migration dependencies.
- `third_party/` contains vendored source with its upstream license and exact
  revision documented.

Do not add a desktop host until the TypeScript core and OpenTUI CLI reach the
parity gate. Do not add a C ABI, generic JSON bridge, daemon, or speculative
executable target. Keep SDK types inside their adapter. Keep terminal policy in
the OpenTUI frontend.

Treat ambient MCP server and tool names as repository-controlled input. A
workspace can shadow built-in names, so permission decisions must not trust a
server/tool-name pair as proof of provenance. Keep ambient MCP permissions
fail-closed until an explicit user approval boundary exists.

## Build and Test

Use Zig 0.16.x, Bun 1.4.2, and TypeScript 7.0.2 during the migration.

```sh
zig build
zig build run -- --help
zig build test
./scripts/check.sh
zigdoc copilot_sdk.Client
bun install --frozen-lockfile
bun run check
bun run verify:compiled-parity
```

Run `bun run probe:runtime` separately when Copilot credentials and the
Copilot CLI are available. Default checks must not require either.
`bun run verify:compiled-parity` builds and executes the Zig and compiled Bun
artifacts for deterministic behavior-parity fixtures; it must not be replaced
with source entrypoints or `bun run` wrappers. Its build and execution
subprocesses are bounded; preserve timeout and process-group termination when
adding parity fixtures.

For platform-specific clipboard or terminal-input changes, cross-build the
executables:

```sh
zig build -Dtarget=x86_64-linux-gnu --prefix zig-out/cli-linux
zig build -Dtarget=x86_64-windows-gnu --prefix zig-out/cli-windows
```

Use the Windows GNU target when cross-building without MSVC headers. Release
CLIs target glibc 2.17 on Linux and macOS 14.0 on Apple silicon. An explicit
macOS target must pass both `--sysroot` and `-Dmacos-sdk` from
`xcrun --sdk macosx --show-sdk-path`.

## Style

Run `zig fmt build.zig backend cli`. Run `bun run typecheck`, `bun test`, and
`bun run boundary-check` for TypeScript changes. Preserve lowercase `vivi` for
the CLI and capitalized `Vivi` for the product name.

Default tests must not require Copilot credentials or a running Copilot CLI.
Keep `skipLibCheck` out of the core and testkit projects. The SDK and OpenTUI
adapter projects, and scripts that import them, may use it only while their
pinned dependency declarations fail TypeScript's library checks.
When changing `backend/src/attachment.zig` or `backend/src/settings.zig`, also
run `zig test` directly on the changed module.

With Zig 0.16 on POSIX, open a directory with `.iterate = true` before calling
`Dir.setPermissions`; the default `openDirAbsolute` handle may be `O_PATH` on
Linux, causing `setPermissions` to abort with `BADF`.

Version every persisted settings schema change. Parse each supported older
version explicitly, migrate it in memory, and test the next write.

## Pull Requests

Keep changes narrowly scoped and include relevant command output in PR
descriptions. User-visible CLI or TUI changes require a reviewer-facing demo
captured through the built application. Never commit generated archives,
caches, credentials, or a Copilot CLI binary.
