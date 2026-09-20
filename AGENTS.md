# Repository Guidelines

## Project Structure

Vivi is a cross-platform Zig CLI:

- `backend/src/root.zig` owns Copilot SDK adaptation and is the only production
  module allowed to import `copilot_sdk`.
- `backend/src/` contains SDK-free domain services for conversations, tools,
  models, settings, presentation, file picking, attachments, and PTYs.
- `cli/src/` owns command parsing and the libvaxis terminal interface.
- `build.zig.zon` is the sole SDK dependency pin.
- `third_party/` contains vendored source with its upstream license and exact
  revision documented.

Do not add native or web application hosts, a C ABI, generic JSON bridges,
daemons, or speculative executable targets. Keep UI policy in the CLI and
Copilot SDK types inside `backend/src/root.zig`.

Treat ambient MCP server and tool names as repository-controlled input. A
workspace can shadow built-in names, so permission decisions must not trust a
server/tool-name pair as proof of provenance. Keep ambient MCP permissions
fail-closed until an explicit user approval boundary exists.

## Build and Test

Use Zig 0.16.x.

```sh
zig build
zig build run -- --help
zig build test
./scripts/check.sh
zigdoc copilot_sdk.Client
```

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

Run `zig fmt build.zig backend cli`. Preserve lowercase `vivi` for the CLI and
capitalized `Vivi` for the product name.

Default tests must not require Copilot credentials or a running Copilot CLI.
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
