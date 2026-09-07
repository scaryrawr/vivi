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
zig build run -- chat
zig build test
zig build install-c-api
```

`vivi chat` opens a full-screen Vivi chat with a scrolling transcript,
workspace context, and a compact bottom composer. It streams responses as they
arrive and restores the composer after each completed turn. Vivi disables
Copilot's built-in tools, built-in MCP servers, custom instructions, and
ask-user capability, then supplies a small replacement system prompt and four
Vivi-owned tools: `read`, `bash`, `edit`, and `write`. Tool output is returned
whole; Copilot owns any large-result handling.
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

Architecture and ownership decisions are documented in
[`docs/architecture.md`](docs/architecture.md).
