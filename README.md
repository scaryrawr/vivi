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

`vivi chat` opens a full-screen Vivi chat with a scrolling transcript,
workspace context, and a compact bottom composer. It streams responses as they
arrive and restores the composer after each completed turn. Vivi enables
Copilot's session-isolated built-in tools for planning and subagent
coordination while keeping built-in MCP servers and custom instructions
disabled. The SDK supplies `ask_user`, while Vivi supplies `read`, `bash`,
`edit`, and `write`; the terminal presents questions in a separate decision
panel with arrow-key choice selection. Typed choice numbers, exact choice text,
and free-form input when allowed remain supported. Tool output is returned
whole; Copilot owns any large-result handling.

In the terminal transcript, tool calls start collapsed. Expanded running calls
show their output when they finish, including failures. Press F6 from the
composer to focus the first visible tool (or the first tool if none is
visible), use Up/Down to move between tools, and Enter or Space to
expand/collapse. A `>` marker and highlighted summary identify focus;
navigation scrolls the tool into view. Escape or F6 returns to the unchanged
composer. Menus and pending questions retain their own keys; Page Up/Down
scroll the transcript. Terminal selection and copying are available through
the terminal's standard gestures and shortcuts.
Details wrap with the terminal width and scroll with the
transcript, on a subtly contrasting background. Input arguments use readable
labels with decoded strings and line breaks, including all additional fields;
nested objects and arrays use indentation and indexed items. Invalid JSON is
explicitly labeled and shown as unparsed input. Output stays literal, not
JSON-decoded or rendered as Markdown. Terminal control characters are escaped.

`vivi models` lists the authenticated Copilot model catalog alongside OMLX
models discovered from `http://localhost:8000/v1/models/status`. Each row
reports its qualified ID, context window, maximum output tokens, and vision
capability when known. Start chat with an explicit hosted model using
`vivi chat --model copilot/<model-id>` or a discovered local model using
`vivi chat --model omlx/<model-id>`. Set `OMLX_BASE_URL` and `OMLX_API_KEY` to
override the local endpoint and credential. Vivi passes OMLX's
`max_context_window` and `max_tokens` values into the Copilot SDK provider
configuration; missing values default to 131072 and 32768 respectively.
The most recently selected `/model` is stored in `~/.vivi/settings.json` and
used by new chats. An explicit `--model` overrides that default for one launch
without changing the stored preference.

During an active chat, type `/` to open Vivi's slash-command menu. The menu
refreshes the Copilot SDK command catalog each time it opens so commands from
late-registering extensions can appear without restarting Vivi. Select
`/model` to switch among the Copilot default, authenticated Copilot models,
and discovered OMLX models. Selecting the active model is a no-op. A successful switch keeps the
visible Vivi transcript but starts a fresh server-side session, so prior turns
are not part of the replacement model's context. Vivi currently executes
`/model` with Vivi's model picker. Vivi records sessions it creates under
`~/.vivi/sessions/`; select `/resume` to filter those sessions by workspace and
continue one later. Copilot CLI remains the authoritative history store, and a
failed resume leaves the current chat active. Compatible SDK-contributed commands,
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
