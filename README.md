# Vivi

Vivi is a cross-platform command-line interface for project-aware Copilot
conversations. Its interactive chat is built with Zig and libvaxis and runs on
Windows, Linux, and macOS.

## Requirements

- Zig 0.16.0
- `zigdoc`
- GitHub Copilot CLI in `PATH` for `vivi chat`

Vivi uses
[`scaryrawr/copilot-sdk-zig`](https://github.com/scaryrawr/copilot-sdk-zig),
pinned in `build.zig.zon`. Copilot credentials are not required for builds or
tests.

## Build and test

```sh
zig build
zig build run -- --help
zig build run -- models
zig build run -- chat
zig build test
./scripts/check.sh
```

The CLI and its tests use LLVM because Zig 0.16.0's default x86_64 backend
crashes compiling the image decoder. Backend-only targets retain Zig's default
selection. Pass `-Dllvm=true` or `-Dllvm=false` to compare compiler backends.

`./scripts/check.sh` runs formatting, tests, CLI smoke checks, and Linux and
Windows cross-builds.

## Chat

Running `vivi` with no command starts the full-screen chat. The interface
includes a scrolling transcript, workspace context, streaming responses,
reasoning and tool activity, slash commands, model selection, session resume,
and a compact bottom composer.

```sh
vivi
vivi chat
vivi chat --model copilot/<model-id> --reasoning high
vivi chat --model omlx/<model-id> --reasoning xhigh
```

Hosted Copilot and OMLX sessions retain the `ask_user`, `skill`, and
`web_fetch` built-ins alongside configured MCP tools and four Vivi tools:
`read`, `bash`, `edit`, and `write`. Ambient workspace MCP permission requests
remain denied until Vivi has an explicit approval flow.

Vivi keeps its Copilot runtime state under `~/.vivi/copilot/`, separate from
the standalone Copilot CLI's `~/.copilot/` directory. The selected model and
reasoning level are stored in `~/.vivi/settings.json`.

Use `/model` to switch models, `/new` to replace the active conversation, and
`/resume` to continue a session from Vivi's private Copilot store. Press
Ctrl-C once for cooperative shutdown and again only if Copilot remains blocked.

## Images

Press **Ctrl-V** or **Alt-V** to paste an image from the system clipboard.
Vivi snapshots the image to a private temporary file and submits it as a typed
attachment when its quoted path remains in the composer. macOS uses AppKit,
Linux uses `wl-paste` or `xclip`, and Windows uses PowerShell clipboard support.

The `read` tool accepts PNG, JPEG, GIF, and WebP images. Supported terminals
can expand PNG, JPEG, and GIF results with Kitty graphics; other terminals
retain the text summary.

## Models

`vivi models` lists authenticated Copilot models and OMLX models discovered
from `http://localhost:8000/v1/models/status`. Set `OMLX_BASE_URL` and
`OMLX_API_KEY` to override the local endpoint and credential.

## Development

```sh
zig fmt build.zig backend cli
zigdoc copilot_sdk.Client
```

Release CLIs target glibc 2.17 on Linux and macOS 14.0 on Apple silicon.
Explicit macOS targets require both `--sysroot` and `-Dmacos-sdk` from
`xcrun --sdk macosx --show-sdk-path`.

Architecture and ownership decisions are documented in
[`docs/architecture.md`](docs/architecture.md).
