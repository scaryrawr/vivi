# Vivi

Vivi is a cross-platform application with native UX on each supported
desktop and one shared Zig core. The repository currently contains a SwiftUI
macOS app and the cross-platform lowercase `vivi` CLI. Windows and Linux apps
are planned but not implemented. The CLI includes the first Vivi product
slice: an interactive streaming chat built with libvaxis and powered by
Copilot.

## Requirements

- Zig 0.16.0
- Xcode 26.6
- `zigdoc`
- GitHub Copilot CLI in `PATH` for `vivi chat`

The shared core uses
[`scaryrawr/copilot-sdk-zig`](https://github.com/scaryrawr/copilot-sdk-zig).
The SDK is pinned in `build.zig.zon`. A GitHub Copilot CLI installation and
credentials are not required for builds or tests.

## Build the CLI and backend

```sh
zig build
zig build run -- --help
zig build run -- models
zig build run -- chat
zig build run -- chat --model omlx/Qwen3.5-9B-mxfp4
zig build test
zig build install-c-api
```

The CLI and its tests use LLVM because Zig 0.16.0's default x86_64 backend
crashes compiling the image decoder. Backend-only targets retain Zig's default
selection. To compare compiler backends, pass `-Dllvm=true` or `-Dllvm=false`
to `zig build` or `./scripts/check-zig.sh`; both run the same tests and checks.

`vivi chat` opens a full-screen Vivi chat with a scrolling transcript,
workspace context, and a compact bottom composer. It streams responses as they
arrive and restores the composer after each completed turn. Hosted Copilot and
OMLX sessions retain the `ask_user`, `skill`, and `web_fetch` built-ins
alongside custom tools and tools from configured MCP servers. The built-in
GitHub MCP server exposes only `web_search`; its other tools remain disabled.
Vivi enables ambient workspace configuration discovery, including workspace
MCP configuration and project skill directories. Copilot also loads the
workspace's instruction files, including top-level `AGENTS.md`. Skills marked
`user-invocable: true` appear in the `/` menu and run through Copilot's skill
prompt when selected. The SDK supplies `ask_user`, while Vivi supplies exactly
four custom tools: `read`, `bash`, `edit`, and `write`. Bash action `run` is the
default synchronous command path. Its `start`, `list`, `read`, `write`, and
`stop` actions manage persistent PTY sessions through later finite tool calls.
PTY output is retained in a bounded buffer, reads wait only for a
caller-selected bounded interval, and the workspace service stops all of its
shells during resume or shutdown. The terminal presents questions in a separate
decision panel with arrow-key choice selection. Typed choice numbers, exact
choice text, and free-form input when allowed remain supported.
Synchronous tool output is returned whole; Copilot owns any large-result
handling.

Vivi keeps personal Copilot customization separate from Copilot CLI by using
`~/.vivi/copilot/` as its runtime configuration directory. Personal extensions
therefore live under `~/.vivi/copilot/extensions/`, and plugin installation and
enablement state does not inherit from `~/.copilot/`.

Mouse-wheel bursts are processed in bounded batches with one redraw per batch,
so rapid scrolling does not replay a separate frame for every queued tick.

Press **Ctrl-V** (or **Alt-V** if your terminal intercepts Ctrl-V) to paste an
image from the system clipboard. Vivi saves it as a private temporary PNG and
inserts its quoted file path at the cursor. Enter and Ctrl-Enter submit the
image as a Copilot attachment along with your message, including steering and
queued follow-ups. You can paste several images, or send just an image.
Images are snapshotted when you submit, so later file changes cannot alter a
queued message. Each image may be up to 20 MiB.
Removing a pasted path from the composer excludes that image from the send;
there are no hidden attachment placeholders. Use a vision-capable model.

Use your terminal's usual paste command for text (for example, Cmd-V on
macOS). Bracketed text paste does not submit embedded newlines or execute
shortcuts. Bitmap paste reads the clipboard on the machine running Vivi;
it does not transfer your desktop clipboard over SSH. macOS uses AppKit,
Linux requires `wl-paste` on Wayland or `xclip` on X11, and Windows uses
Windows PowerShell's clipboard support. Clipboard errors leave the draft intact.
Pasted files stay available for the lifetime of the chat, including queued
messages and tool reads, and are removed on normal exit. Their temporary paths
are not durable references for later `/resume` sessions.

The `read` tool also returns PNG, JPEG, GIF, and WebP files as image content
to the model, detecting their format from the bytes rather than the extension.
Image reads show a short file/MIME summary in the transcript, never base64.
`offset` and `limit` apply only to text and are rejected for images.
Expand an image-read result to see a bounded, aspect-preserving preview using
libvaxis's built-in Kitty graphics support. It scrolls and clips with the tool
details. Terminals without Kitty graphics retain the summary; unsupported
preview formats show a notice without changing the image sent to the model.
The current libvaxis decoder supports PNG, JPEG, and GIF previews, but not WebP.
Preview decoding and encoding share a 64 MiB scratch-memory budget, with a
16,777,216-pixel limit; exceeding either shows an unavailable notice without
changing the image sent to the model.

In the terminal transcript, tool calls start collapsed. Click a tool row
(marked `▸`) to expand its complete actual input and output; click it again
to collapse (`▾`). Expanded running calls show their output when they finish,
including failures. For keyboard access, press F6 from the composer to focus
the first visible tool (or the first tool if none is visible), use Up/Down to
move between tools, and Enter or Space to expand/collapse. A `>` marker and
highlighted summary identify focus; navigation scrolls the tool into view.
Escape or F6 returns to the unchanged composer. Menus and pending questions
retain their own keys; Page Up/Down and mouse scrolling still work.
Details wrap with the terminal width and scroll with the
transcript, on a subtly contrasting background. Input arguments use readable
labels with decoded strings and line breaks, including all additional fields;
nested objects and arrays use indentation and indexed items. Invalid JSON is
explicitly labeled and shown as unparsed input. Output is not JSON-decoded;
successful Markdown file reads are rendered as Markdown, while other output
stays literal. Complete terminal control sequences are stripped, while
malformed or unterminated controls are visibly escaped.

`vivi models` lists the authenticated Copilot model catalog alongside OMLX
models discovered from `http://localhost:8000/v1/models/status`. Each row
reports its qualified ID, context window, maximum output tokens, and vision
capability when known, plus its selectable reasoning levels and advertised
default. Start chat with an explicit hosted model using
`vivi chat --model copilot/<model-id> --reasoning high` or a discovered local
model using `vivi chat --model omlx/<model-id> --reasoning xhigh`. `off` sends
no explicit reasoning effort and delegates to the model default. Hosted models
use the levels advertised by GitHub; local models expose
`off,low,medium,high,xhigh`. Set `OMLX_BASE_URL` and `OMLX_API_KEY` to
override the local endpoint and credential. Vivi passes OMLX's
`max_context_window` and `max_tokens` values into the Copilot SDK provider
configuration; missing values default to 131072 and 32768 respectively.
The most recently selected model and reasoning pair is stored in
`~/.vivi/settings.json` and used by new chats. Explicit `--model` and
`--reasoning` values override that default for one launch without changing the
stored preference.

Vivi launches Copilot CLI with a private home at `~/.vivi/copilot/`. This keeps
Copilot sessions, installed extensions, plugin state, and related runtime
configuration separate from the user's normal `~/.copilot/` installation while
still allowing ambient configuration from the active workspace. Workspace MCP
tools are discovered but denied when they request permission until Vivi has an
explicit user-approval flow; the built-in GitHub `web_search` tool is the only
MCP tool automatically approved.

During an active chat, type `/` to open Vivi's slash-command menu. The menu
refreshes the Copilot SDK command catalog each time it opens so commands from
late-registering extensions can appear without restarting Vivi. Select
`/model` to switch among each valid model and reasoning combination for the
Copilot default, authenticated Copilot models, and discovered OMLX models.
Selecting the active pair is a no-op. A successful switch keeps the visible
Vivi transcript but starts a fresh server-side session, so prior turns are not
part of the replacement model's context. Vivi currently executes
`/model` with Vivi's model picker. Select `/resume` to filter sessions stored
by Copilot CLI in Vivi's private home and continue one from any workspace.
Resume rows show the saved title and working directory without exposing
Copilot's session IDs. A successful resume uses the currently selected model
and reasoning effort, replaces the terminal transcript with the persisted
Copilot message history, then reports success. A failed resume leaves the
current chat and transcript active. Compatible SDK-contributed commands,
including session-mode commands such as `/autopilot`, execute through
Copilot's command API.

Use Page Up and Page Down to inspect the transcript. Press Ctrl-C to stop. If
Copilot is blocked and cannot reach an SDK event boundary, press Ctrl-C again
to restore the terminal and force exit.

Installed artifacts are written to `zig-out/`:

- `bin/vivi`
- `lib/libvivi_backend.a`
- `include/vivi_backend.h`
- `include/module.modulemap`

Inspect the pinned SDK directly through the root build graph:

```sh
zigdoc copilot_sdk.Client
```

## Build the macOS app

```sh
xcodebuild \
  -project macos/Vivi.xcodeproj \
  -scheme Vivi \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Opening `macos/Vivi.xcodeproj` and running the shared `Vivi` scheme invokes
the same Zig build through an aggregate target before linking the app.

## Native platform applications

- `macos/` contains the current SwiftUI app, using AppKit where native
  integration requires it.
- `windows/` defines the future WinUI 3 application boundary.
- `linux/` defines the future GNOME application boundary using GTK 4 and
  libadwaita.

Each native build owns its toolkit, packaging, and OS integration. Native apps
consume the C ABI; shared product and Copilot behavior stays in Zig.
`./scripts/check.sh` also cross-builds the Linux shared object and Windows
x64/ARM64 DLLs without claiming that those GUI applications exist yet.

## Check the repository

```sh
./scripts/check.sh
```

The full check composes three independently runnable CI domains:

```sh
./scripts/check-zig.sh
./scripts/check-c-api-cross.sh
./scripts/check-macos.sh
```

Architecture and ownership decisions are documented in
[`docs/architecture.md`](docs/architecture.md).
