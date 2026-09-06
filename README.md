# Vivi

Vivi is a cross-platform application with native UX on each supported
desktop and one shared Zig core. The repository currently contains a SwiftUI
macOS app and the cross-platform lowercase `vivi` CLI. Windows and Linux apps
are planned but not implemented; Copilot product behavior is also still a
scaffold.

## Requirements

- Zig 0.16.0
- Xcode 26.6
- `zigdoc`

The shared core will use
[`scaryrawr/copilot-sdk-zig`](https://github.com/scaryrawr/copilot-sdk-zig).
The SDK is pinned in `build.zig.zon`. A GitHub Copilot CLI installation and
credentials are not required for the scaffold builds or tests.

## Build the CLI and backend

```sh
zig build
zig build run -- --help
zig build test
zig build install-c-api
```

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
