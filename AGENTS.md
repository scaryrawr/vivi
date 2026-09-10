# Repository Guidelines

## Project Structure & Module Organization

Vivi targets Windows, Linux, and macOS with one authoritative Zig backend and
platform-native UX:

- `backend/src/root.zig` owns domain behavior and is the only production module allowed to import `copilot_sdk`.
- `backend/src/c_api.zig` adapts domain values to the stable C ABI in `backend/include/vivi_backend.h`; keep SDK, JSON-RPC, subprocess, and Zig-owned memory types out of this boundary.
- `cli/src/main.zig` imports `vivi_backend` directly.
- `macos/` owns the SwiftUI/AppKit app and XCTest integration.
- `windows/` documents the future WinUI 3 / Windows App SDK host.
- `linux/` documents the future GNOME GTK 4 / libadwaita host.
- `build.zig.zon` is the sole SDK dependency pin. Build products belong in ignored `.zig-cache/`, `zig-pkg/`, `zig-out/`, or Xcode Derived Data.

Native hosts share domain semantics through the C ABI, not widgets or view
models. Do not add speculative sessions, generic JSON bridges, daemons, shared
UI abstractions, or empty executable targets.

## Build, Test, and Development Commands

Use Zig 0.16.x and Xcode 26.6.

```sh
zig build                         # CLI, static library, C header/module map
zig build run -- --help           # narrow CLI smoke path
zig build test                    # Zig unit tests plus C ABI smoke test
zigdoc copilot_sdk.Client         # inspect the pinned SDK
```

The Xcode `BuildViviBackend` target invokes `scripts/build-zig-for-xcode.sh`.
Future MSBuild and Meson projects should call `zig build install-c-api` rather
than creating another Zig dependency graph.

```sh
xcodebuild -project macos/Vivi.xcodeproj -scheme Vivi \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
./scripts/check.sh                 # full format, Zig, CLI, and Xcode checks
```

## Coding Style & Naming Conventions

Run `zig fmt build.zig backend cli` for Zig. Run `xcrun swift-format format --in-place --recursive macos/Vivi macos/ViviTests` for Swift. Preserve lowercase `vivi` for the CLI and capitalized `Vivi` for app/product names.

## Testing Guidelines

Keep backend and SDK adaptation tests in Zig, ABI agreement in the C smoke
test, and native binding/UX behavior in each platform's test framework.
Default tests must not require Copilot credentials or a running Copilot CLI.
Any C ABI change must update the header, Zig adapter, smoke test, and every
implemented native binding together.

## Commit & Pull Request Guidelines

No commit convention exists yet. Keep changes narrowly scoped and include the
relevant command output in PR descriptions.

Every PR that changes user-visible CLI, TUI, or native app behavior must include
a reviewer-facing demo in its description. Use a short GIF or video when the
behavior changes over time. Use before-and-after screenshots when a static
comparison is clearer. Exercise the built application through the same surface
the user sees. Unit tests, terminal transcripts, and written claims do not
replace the visual demo. If the host cannot capture or upload media, state the
specific blocker in the PR description and do not present the PR as visually
verified.

Never commit generated archives, caches, Derived Data, credentials, or a
Copilot CLI binary.
