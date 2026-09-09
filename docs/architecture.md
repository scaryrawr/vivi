# Architecture

## Problem

Vivi is intended for Windows, Linux, and macOS with a native experience on
each platform. A shared Zig core and the cross-platform `vivi` CLI converge on
one backend built on `copilot-sdk-zig`, whose API is blocking, single-threaded,
and starts Copilot CLI over stdio. The implementation must preserve
platform-native UX without duplicating sessions, prompts, tools, persistence,
or transport policy in each application.

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

The C ABI intentionally exposes one status function. The CLI's first product
operation is a backend-owned conversation worker with a libvaxis terminal
adapter. Product operations will
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

For the CLI chat, `backend/src/conversation.zig` owns the worker, one-command
mailbox, owned event queue, and lifecycle state. `backend/src/root.zig` owns
the SDK adapter and remains the only production module that imports
`copilot_sdk`. The libvaxis loop receives only a payload-free wake; the CLI
then transfers owned domain events from the backend and reduces them into a
private `ChatUi`. `ChatUi` owns the transcript, composer, responsive frame
layout, and a wrapped-row viewport used for Page Up and Page Down scrolling.
This keeps SDK values and their allocator lifetimes off the UI thread while
keeping terminal policy out of the backend.

The initial coding-agent policy is private to `backend/src/root.zig`. Copilot
CLI starts with the SDK's curated session-isolated built-in tools enabled for
planning and subagent coordination, while built-in MCP servers and custom
instructions remain disabled. The SDK provides its typed `ask_user` callback;
the session registers Vivi-owned `read`, `bash`, `edit`, and `write` tools and
replaces Copilot's system message with Vivi's concise workspace-aware prompt.
Source-qualified tool filters keep host-affecting built-ins unavailable
without suppressing Vivi tools.

`backend/src/tools.zig` owns SDK-free tool behavior: JSON argument validation,
workspace-relative path resolution, text reads, Bash execution, exact
multi-edit planning, line-ending/BOM preservation, and file writes. It returns
owned text or an actionable failure. `backend/src/root.zig` owns the four SDK
declarations and explicitly resolves `external_tool_requested` events so full
failure messages reach the model rather than being reduced to Zig error names.
The tool layer does not truncate output or create spill files because Copilot
owns large-result handling.

`backend/src/models.zig` owns the first local-model integration: OMLX discovery
through `/v1/models/status`, response validation, stable `omlx/<model-id>`
identities, and model metadata ownership. It preserves OMLX's
`max_context_window`, `max_tokens`, and `llm`/`vlm` classification, with
131072-token context and 32768-token output defaults when the server omits
those values. The CLI may list these SDK-free domain values, but only
`backend/src/root.zig` translates a selected model into
`copilot.ProviderConfig`.

An OMLX conversation owns a copied selection and endpoint configuration in
the conversation runner context. The SDK worker rediscovers the exact model
before session creation and passes its detected prompt and output limits in
the initial provider configuration. Session creation fails when the selected
model or endpoint is unavailable; Vivi does not retry as a hosted model.
Provider credentials are copied into the runner context, never logged, and
zeroed before release.

Hosted-model discovery and slash-command discovery also cross the SDK boundary
only in `backend/src/root.zig`. The worker translates typed
`Client.listModels` results into provider-qualified `copilot/<model-id>`
entries, filters policy-disabled models, and preserves `copilot/default` as
the no-explicit-selection identity. Explicit hosted plans retain the raw SDK
model ID and pass it through `SessionConfig.model`; OMLX plans continue to use
`ProviderConfig`.

The SDK's generic `Client.callRpc` adapts `session.commands.list` into the
SDK-free command catalog owned by
`backend/src/conversation.zig`. It refreshes that catalog after session
creation, after session replacement, when an unknown SDK event identifies
`commands.changed`, and whenever the terminal opens `/`. The explicit open-time refresh is
required because the single SDK-owning worker waits on Vivi's command mailbox
while idle and cannot concurrently wait for SDK events from late-registering
extensions.

`cli/src/chat.zig` owns the generic slash menu, filtering, selection,
navigation, viewport, and responsive layout. `TextInput` remains the sole
owner of composer text; the menu stores only catalog entries and filtered
indices. `/model` opens a backend-supplied catalog containing
`copilot/default`, authenticated and policy-eligible hosted models, and
discovered local models with context, output, and vision metadata. Other
compatible SDK-contributed commands execute through
`session.commands.invoke`. Vivi's `ask_user` tool requests cross the backend as
owned domain events; the terminal shows the question and choices, then returns
the composer's answer as the tool result.

Model replacement is a transaction on the SDK worker. It resolves the target
and creates a candidate session before disconnecting the active session. A
creation failure leaves the original session active; selecting the active
identity performs no work. After successful candidate creation, the worker
atomically stores the canonical model identity in `~/.vivi/settings.json`,
commits the candidate session and provider plan, and then detaches the previous
session as cleanup. The terminal preserves its visible transcript while
explicitly reporting that the new server-side session has no prior
conversational history. An explicit CLI `--model` overrides the stored default
for one launch; selecting that already-active override through `/model`
promotes it to the persisted default without replacing the SDK session.

`backend/src/settings.zig` owns the versioned, SDK-free settings document and
atomic replacement. Writers coordinate through a sidecar lock, and rollback
uses a monotonic document revision captured by the exact write, so a failed
model switch cannot overwrite a newer default saved by another process or be
fooled by the same model value appearing again. Hosts resolve the user's home
directory and pass the settings path into conversation options; they do not
parse the document or coordinate model-switch persistence. Copilot CLI
continues to own its session storage. The SDK can create or join sessions by
ID, but does not expose a custom session-storage backend.

`backend/src/session_store.zig` owns Vivi's durable index of sessions it
created. Processes coordinate through an advisory `.lock` file under
`~/.vivi/sessions/`. While holding that lock, each read or write merges valid
versioned JSON shards by SDK session ID, incrementally bounds the catalog,
atomically writes the merged catalog to the current process's shard, and
removes sibling shards. Malformed shards are skipped and then removed during
compaction. An unsupported document version aborts the operation so an older
Vivi binary cannot delete a newer catalog. On POSIX systems, the directory,
lock, and shards use owner-only permissions; Windows creation inherits the
user profile's access-controlled directory permissions. The store records only
the session ID, working directory, model identity, and recency; Copilot CLI
remains the sole transcript/history store.

`/resume` is a first-class broker control operation rather than an SDK slash
command. The terminal receives display-ready rows with request-local numeric
keys, while `backend/src/root.zig` privately resolves the selected record and
calls `Client.joinSession`. Joining, durable recency update, active-session
commit, and previous-session cleanup form one backend transaction. Candidate
tools and the system prompt are rebuilt for the recorded working directory;
any failure before commit leaves the current session active.

Cancellation is cooperative because the pinned SDK has no documented
cross-thread operation that interrupts a blocked `Session.nextEvent`.
`requestStop` is observed by the SDK-owning worker at an event boundary, where
it calls `Session.disconnect`. A second Ctrl-C is a deliberate hard-exit path
for a permanently blocked Copilot process.

## Synthesis decision

The real macOS project lives in top-level `macos/`. Top-level
`windows/` and `linux/` contain only platform contracts until their apps are
buildable. This keeps the repository truthful while establishing native
ownership early. All native build systems call the root `install-c-api` step;
the macOS staging script is not a template for Windows because Windows ships
separate architecture-specific binaries rather than a fat archive.

The CLI chat uses a backend conversation broker rather than a CLI-owned SDK
worker. The broker was chosen because its small submit/take/stop/deinit
surface hides SDK sequencing, single-thread ownership, event copying, and
teardown. libvaxis remains a CLI-only dependency, and the native C ABI remains
unchanged until a native caller defines its callback and ownership contract.

The minimal agent configuration stays private to the SDK-owning root module
rather than becoming caller-supplied conversation options. This keeps tool
availability and prompt policy consistent across every host. The process-level
built-in exclusion is authoritative for Copilot-provided capabilities while
leaving extension/custom tool sources eligible. The SDK declarations use the
same four descriptors that drive the SDK-free dispatcher, and permission
requests remain fail-closed because Vivi has no approval UI yet.

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
- We accept copied streaming text in exchange for explicit ownership across
  the backend worker and terminal thread.
- We accept cooperative cancellation in exchange for never calling the
  single-threaded SDK concurrently.
- We accept CLI launch flags alongside SDK session configuration because the
  pinned Zig SDK does not expose Copilot's source-qualified tool allowlist.
- We accept unbounded in-memory tool results in exchange for leaving
  truncation and large-result transport to Copilot.
- We accept synchronous tool execution on the SDK worker in exchange for one
  clear owner and serialized file mutations.
- We accept rediscovering the selected OMLX model at conversation startup in
  exchange for never launching with stale context limits or a removed model.
- We accept OMLX as the first local provider slice in exchange for proving the
  provider/session path before generalizing discovery across more protocols.
- We accept explicit command refresh when `/` opens in exchange for preserving
  one SDK-owning thread and still observing late extension registration.
- We accept resetting server-side history during model replacement in exchange
  for an atomic create-before-disconnect transition with no provider-specific
  transcript replay.
- We accept rendering command completion as concise status text because the
  terminal does not reproduce every interactive dialog owned by Copilot CLI.

## Alternatives considered

- A shared cross-platform UI toolkit was rejected because it would force
  platform UX into one widget and lifecycle model.
- A local daemon was rejected because it would add another process lifecycle
  and wire protocol before any core behavior exists.
- Symmetric placeholder applications were rejected because empty WinUI and
  GNOME targets would falsely claim product support.
- A CLI-owned SDK worker was rejected because every future native host would
  have to recreate SDK sequencing, thread ownership, and event lifetime policy.
- A callback-based stream was rejected because callback lifetime and thread
  affinity would become part of every caller's contract.
- An SDK-only empty `tools` list was rejected because it controls external
  handlers registered by Vivi, not Copilot's built-in tool inventory.
- Allowing the complete `builtin:*` class was rejected because newly shipped
  privileged tools could bypass Vivi's policy; the source-qualified allowlist
  admits only the reviewed session-isolated built-ins.
- Caller-supplied agent configuration was rejected because it would leak
  Copilot process and prompt policy into every CLI and native host.
- SDK auto-handlers were rejected because they reduce operational failures to
  Zig error names and still return the external-tool event to the caller.
- Pi's tool-side truncation and spill files were rejected because Copilot
  already owns large tool-result handling.

## Open questions

- Should a distributed app bundle Copilot CLI or expose a preference that maps
  to `ClientOptions.cli_path`?
- Which process-launch and credential-storage differences require the first
  private OS runtime adapters?
- What transcript retention limit should replace the current process-lifetime
  in-memory history if long-running conversations make one necessary?
- What authorization and approval UI should eventually replace the current
  `skip_permission` policy for Vivi-owned tools?

## Next implementation step

Use the first native-host caller to define the C ABI conversation handle and
callback contract.
