# Architecture

## Problem

Vivi is intended for Windows, Linux, and macOS with a native experience on
each platform. A shared Zig core and the cross-platform `vivi` CLI converge on
one backend built on `copilot-sdk-zig`, whose API is blocking, single-threaded,
and starts Copilot CLI over stdio. The scaffold must preserve platform-native
UX without duplicating sessions, prompts, tools, persistence, or transport
policy in each application.

## Usage

The CLI imports `vivi_backend` directly. Native GUI applications import the
`ViviBackend` C API and translate its domain values into platform-owned models.
No native host imports `copilot_sdk`, JSON-RPC types, subprocess handles, or
Zig-owned memory.

## Shape

The root Zig package owns the SDK dependency, shared domain module, CLI, and
C-compatible library. `backend/src/root.zig` is the only production module
allowed to import `copilot_sdk`. `backend/src/c_api.zig` adapts domain values
to the versioned C header; it does not own product behavior.

Native applications are intentionally asymmetric:

| Host | Native UX and build ownership | Core artifact |
| --- | --- | --- |
| `macos/` | SwiftUI, AppKit, Xcode, app bundle, signing | Universal static archive assembled with `lipo` |
| `windows/` | WinUI 3, Windows App SDK, MSBuild, deployment and MSIX | One DLL and import library per x86/x64/ARM64 architecture |
| `linux/` | GNOME, GTK 4, libadwaita, Meson, desktop integration and packaging | Static archive or shared object selected by the native build |

Only the macOS application exists today. Windows and Linux directories record
their decided native stacks and build contracts; executable targets arrive
with their first buildable product slice.

The scaffold currently verifies:

- `x86_64-linux-gnu` as `libvivi_backend.so`;
- `x86_64-windows-msvc` as a DLL and import library in Debug;
- `aarch64-windows-msvc` as a DLL and import library in ReleaseSafe.

Zig 0.16 currently fails while cross-compiling its `libubsan` support for
ARM64 Windows Debug from macOS. Treat that as a toolchain verification item,
not as a reason to add target conditionals to domain code.

The C ABI intentionally exposes one status function. Product operations will
be added only after a real caller defines their domain shape. Extensible
structs must carry `abi_version` and `struct_size`; text crosses as UTF-8 bytes
with explicit lengths; state uses opaque handles with matching destroy
functions. Platform export/import decoration belongs to packaging adapters,
never domain code.

The SDK's blocking work must never run on SwiftUI's main actor, GLib's main
loop, or the WinUI dispatcher thread. Threading, callback lifetime, and
cancellation become part of each concrete operation's contract. If core code
eventually needs OS services such as process discovery or credential storage,
add private `backend/src/runtime/<os>.zig` adapters only when required; core
and CLI code must continue compiling without a UI adapter.

## Synthesis decision

The real macOS project lives in top-level `macos/`. Top-level
`windows/` and `linux/` contain only platform contracts until their apps are
buildable. This keeps the repository truthful while establishing native
ownership early. All native build systems call the root `install-c-api` step;
the macOS staging script is not a template for Windows because Windows ships
separate architecture-specific binaries rather than a fat archive.

## Tradeoffs accepted

- We accept a checked-in Xcode project in exchange for a clean checkout that
  needs no project generator.
- We accept an Xcode shell build phase in exchange for one authoritative Zig
  dependency graph and architecture-correct native artifacts.
- We accept a C ABI in exchange for a stable language boundary that does not
  expose Zig or SDK representations.
- We accept synchronous backend internals in exchange for matching the SDK
  honestly; Swift concurrency policy will be introduced with the first real
  operation.
- We accept separate native build systems and duplicated view code in exchange
  for first-class platform UX instead of a least-common-denominator UI layer.

## Alternatives considered

- A shared cross-platform UI toolkit was rejected because it would force
  platform UX into one widget and lifecycle model.
- A local daemon was rejected because it would add another process lifecycle
  and wire protocol before any core behavior exists.
- Symmetric placeholder applications were rejected because empty WinUI and
  GNOME targets would falsely claim product support.

## Open questions

- What is the first user-visible operation that should define the opaque
  backend handle and event contract?
- Should a distributed app bundle Copilot CLI or expose a preference that maps
  to `ClientOptions.cli_path`?
- Which process-launch and credential-storage differences require the first
  private OS runtime adapters?

## Next implementation step

Verify the core and dynamic C library for Linux and Windows targets, then
define the first conversation use case from CLI and native-host caller views.
