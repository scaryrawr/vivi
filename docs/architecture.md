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

`backend/src/canvas.zig` is the renderer-neutral, SDK-free canvas domain.
Bounded UTF-8 identity types preserve the evidenced extension, canvas, and
instance key; role-specific JSON types prevent schemas, open inputs, action
inputs, and action results from being exchanged accidentally. Registry
knowledge, runtime state (`opened`, `closed`, or `unavailable`, with local
opening/closing work), and durable state (`recorded` or `removed`) remain
orthogonal in each conversation.

The canvas reducer accepts registry replacement and incremental updates as
different tagged inputs because the SDK contract does not establish whether a
registry event is a snapshot or delta. A future adapter must label that
meaning from additional evidence rather than infer it. Provider lifecycle
signals contain no operation correlation; Vivi's monotonic operation IDs and
renderer generations are local ordering tools only. Reopening the same key is
represented as another evidenced open request with a new local generation,
not as an invented provider reopen method.

Canvas limits are checked before valid registry, input, renderer, or recording
state is replaced. Backpressure and protocol degradation are scoped, shutdown
cancels pending local work, and resume projection contains only evidenced
recorded open-canvas identity, title, and input fields. Transient URL, status,
and renderer generation never enter resume state.

The production SDK adapter lives privately in `backend/src/root.zig`. One
adapter and one `canvas.State` follow each active SDK session, and canvas
commands use the same serialized conversation worker as prompts and other
control operations. SDK method results complete only the Vivi operation that
issued that method; provider lifecycle events remain independent authoritative
observations. Queue-visible commands, completions, and snapshots are owned
SDK-free values.

`ConversationOptions.request_extensions` and
`request_canvas_renderer` both default to `false`. The adapter requests only
the selected public SDK features and does not add model-visible canvas tools or
Vivi-owned declarations. Registry events are bounded and validated, but the
production adapter does not apply them because the public API still does not
establish replacement-versus-delta meaning. Its root-private adapter mode
keeps replacement behavior available only to credential-free fixtures until
runtime evidence resolves that gate. Join/resume `open_canvases` is likewise
omitted; the adapter uses the public snapshot only as positive observations and
never treats absence as closure. Native or CLI rendering remains later host
work.

ABI v9 exposes the existing canvas domain through one disabled-by-default
`canvas_mode`, one typed `vivi_backend_perform_canvas` operation, and the
existing transactional event drain. Snapshot events flatten declarations,
actions, and instances into caller-owned typed arrays with spans into the
event byte buffer; completion events carry the local operation ID and typed
outcome. The C boundary validates and copies operation input before return,
and any undersized event destination leaves every payload buffer untouched
while retaining the event for an identical retry. Current native call sites
select `VIVI_BACKEND_CANVAS_DISABLED` and perform no canvas decoding or
rendering. PR 5 remains the gate for host opt-in and user-visible behavior.

The macOS PR 5 integration keeps `ViviConversationDriver` as the sole C
boundary. It copies every event buffer in one exact-capacity transaction,
strictly decodes canvas values into owned Swift types, and routes them to one
`NativeCanvasStore` owned by each `NativeChatStore`. That store owns registry
and instance reconciliation, operation-ID correlation, generation-bound
actions, retained declaration metadata, and explicit renderer teardown.
Window selection and red-close do not affect it; successful session resume
tears down and resets it before accepting the resumed conversation's
snapshots. Application termination tears it down before closing the backend.
The production driver continues to select `VIVI_BACKEND_CANVAS_DISABLED`.

PR 6 is the earliest point at which macOS may add a canvas renderer. Its
security gate requires a separately reviewed `WKWebView` design with a
nonpersistent data store, no ambient network access, a deny-by-default
navigation policy, no arbitrary host-file access, an allowlisted and
schema-validated script-message bridge, generation checks on every callback,
and deterministic teardown of content worlds, handlers, tasks, and web views.
PR 5 intentionally adds no SwiftUI canvas surface, WebView, URL loading, or
network behavior.

Native applications are intentionally asymmetric:

| Host | Native UX and build ownership | Core artifact |
| --- | --- | --- |
| `macos/` | SwiftUI, AppKit, Xcode, app bundle, signing | Universal static archive assembled with `lipo` |
| `windows/` | WinUI 3, Windows App SDK, MSBuild, deployment and MSIX | One DLL and import library per x86/x64/ARM64 architecture |
| `linux/` | GNOME, GTK 4, libadwaita, Meson, desktop integration and packaging | Static archive or shared object selected by the native build |

Only the macOS application exists today. Windows and Linux directories record
their decided native stacks and build contracts; executable targets arrive
with their first buildable product slice.

The macOS app owns one logical main-window presentation and an ordered,
in-memory collection of live conversations. A canonical absolute workspace
path identifies project context, a fresh conversation ID identifies one
`NativeChatStore` and driver pair, and the main-window identity remains
independent of both. Every valid `vivi://chat?workspace=...` occurrence creates
and selects a new conversation, including a repeated workspace. Closing the
window releases only its AppKit and SwiftUI presentation; Dock reopen rebuilds
that presentation over the same conversation collection and selection.
Application termination closes every retained store and waits for all drivers.

`NativeChatStore` remains the authoritative one-conversation aggregate. The
application collection derives sidebar title and workspace metadata from the
store rather than copying it. This permits a session resume to replace the
store's active workspace, title, transcript, and model selection without
changing application conversation identity. The sidebar does not parse session
shards, retain backend resume keys, or own transcript and model behavior.

The scaffold currently verifies:

- `x86_64-linux-gnu` as `libvivi_backend.so`;
- `x86_64-windows-gnu` as a DLL and import library in Debug;
- `aarch64-windows-gnu` as a DLL and import library in ReleaseSafe.

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
Packaged native apps must not rely on an interactive shell's `PATH` to find
Copilot. The host resolves a trusted executable to an absolute path and passes
that copied path through the typed C ABI.

For the CLI chat, `backend/src/conversation.zig` owns the worker, one-command
mailbox, owned event queue, and lifecycle state. `backend/src/root.zig` owns
the SDK adapter and remains the only production module that imports
`copilot_sdk`. The libvaxis loop receives only a payload-free wake; the CLI
then transfers owned domain events from the backend and reduces them into a
private `ChatUi`. `ChatUi` owns the transcript, composer, responsive frame
layout, and a wrapped-row viewport used for Page Up and Page Down scrolling.
This keeps SDK values and their allocator lifetimes off the UI thread while
keeping terminal policy out of the backend.

Image clipboard access and temporary-file ownership belong to the CLI.
The composer inserts a literal quoted path, and only retained pasted-path
tokens are selected as attachments at submission. `Conversation.submit`
snapshots the selected image bytes into an owned message, so queued sends
and steering never borrow editor memory or reread modified files. The image
store outlives the conversation worker and removes only the temporary files it created after
that worker stops. Saved ask-user drafts retain their visible image paths.
Only `root.zig` maps the snapshots into typed `session.send` blob attachments
through `MessageOptions.message_attachments`; the SDK's RPC details stay out of
the SDK-free conversation boundary.
No chat operation is exposed through the scaffold C ABI.
On Windows, Vivi drives the libvaxis terminal parser and existing event queue
directly to preserve paste-boundary events omitted by the pinned library's
Windows loop adapter. All other events still use libvaxis's generic forwarding;
input failures are delivered to the app for normal terminal cleanup.

The initial coding-agent policy is private to `backend/src/root.zig`. Hosted
Copilot sessions enable the SDK's curated session-isolated built-ins for
planning and subagent coordination. OMLX sessions omit the entire task and
agent-orchestration built-in family because Vivi owns one local model at a
time, retaining only `ask_user` and `skill`. Built-in MCP servers and ambient
workspace configuration discovery remain disabled for both. Vivi explicitly
supplies the workspace root for instructions and `.github/skills`,
`.agents/skills`, and `.claude/skills` for skills. The SDK provides its typed `ask_user` callback; the session registers exactly
four Vivi-owned tools: `read`, `bash`, `edit`, and `write`. The `bash` tool
dispatches synchronous `run` plus persistent PTY `start`, `list`, `read`,
`write`, and `stop` actions. Vivi appends its concise workspace-aware prompt to
Copilot's system message. Provider-specific
session-level source-qualified allowlists admit custom and extension tools
while limiting Copilot's built-ins to the applicable reviewed set.

`backend/src/tools.zig` owns SDK-free tool behavior: JSON argument validation,
workspace-relative path resolution, text/image reads, synchronous Bash
execution, async Bash tool adaptation, exact multi-edit planning,
line-ending/BOM preservation, and file writes. It returns
owned text, image bytes with a detected format and display summary, or an
actionable failure. `backend/src/root.zig` owns the four SDK
declarations and explicitly resolves `external_tool_requested` events so full
failure messages reach the model rather than being reduced to Zig error names.
The tool layer does not truncate output or create spill files because Copilot
owns large-result handling.
Image results are translated there into the SDK's structured
`binaryResultsForLlm` with base64 data and a MIME type. The tool-activity queue
carries an owned image snapshot and summary; base64 never becomes transcript
text. Expanded tool results load previews through libvaxis/zigimg, reserve
bounded rows in the transcript projection, and crop placements to the visible
viewport. Terminal graphics handles live until app shutdown; unsupported
terminals or decoder formats show a notice instead. Preview decoding and
encoding share a capped 64 MiB scratch allocator. PNG dimensions are checked
before decoding, and previews are limited to 16,777,216 pixels. The SDK-free read
service separately limits image-file bytes and rejects text line ranges on
images and unsupported binary text reads.
Reads inspect a fixed-size prefix on one open file handle before allocating
contents. Recognized images use a bounded reader; ordinary text keeps its
existing unlimited behavior.

`backend/src/bash_sessions.zig` is the deep, SDK-free owner of async Bash
sessions. One manager is initialized lazily inside each workspace-scoped
`tools.Service`; successful resume therefore stops the old workspace's
processes, failed resume leaves them intact, and model switches preserve them.
The manager owns opaque IDs, separately allocated session state, bounded input
and output rings, reader/writer/waiter threads, PTY endpoints, and idempotent
stop. Reads consume up to 32 KiB after a bounded wait, output retention is
256 KiB per shell, writes are accepted atomically into a 64 KiB queue, and at
most eight shells are retained.

`backend/src/pty/platform.zig` hides the private native PTY ABI. macOS and
Linux use `openpty` plus a supervisor that owns the Bash process group and
kills it when Vivi closes the control socket, including forced exit. The
supervisor reports exit independently of PTY EOF; the reader normalizes Linux
`EIO` and macOS zero-length reads, and natural exit is published only after
both output EOF and process status arrive. Windows uses ConPTY and launches
`bash.exe` suspended before assigning it to a kill-on-close Job Object. Only
the target-selected native adapter is compiled. No PTY handle, PID, ConPTY type, or
libvaxis dependency crosses into the tool or SDK layers.

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
Vivi also passes the detected vision capability through
`SessionConfig.model_capabilities` on both session creation and resume.
Unknown BYOK model names otherwise default to no vision in Copilot, which
removes image content before it reaches OMLX.

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
uses a random identity captured by the exact write, so a failed model switch
cannot overwrite a newer default saved by another process, be fooled by the
same model value appearing again, or mistake a legacy writer's field-dropping
rewrite for its own write. Hosts resolve the user's home directory and pass the
settings path into conversation options; they do not parse the document or
coordinate model-switch persistence. Copilot CLI continues to own its session
storage. The SDK can create or join sessions by ID, but does not expose a
custom session-storage backend.

`backend/src/session_store.zig` owns Vivi's durable index of sessions it
created. Processes coordinate through an advisory `.lock` file under
`~/.vivi/sessions/`. While holding that lock, each read or write merges valid
versioned JSON shards by SDK session ID, incrementally bounds the catalog,
atomically writes the merged catalog to the current process's shard, and
best-effort removes sibling shards after that commit. Malformed shards are
skipped and then removed during compaction. An unsupported document version or
an oversized shard aborts the operation before compaction so an older Vivi
binary cannot delete a newer catalog it cannot safely inspect. On POSIX
systems, the directory, lock, and shards use owner-only permissions; Windows
creation inherits the user profile's access-controlled directory permissions.
The store records only the session ID, generated title, working directory,
model identity, and recency, refreshing recency after each completed response;
Copilot CLI remains the sole transcript/history store.

`/resume` is a first-class broker control operation rather than an SDK slash
command. Bare `/resume` lists only Vivi's private local index. `/resume all`
uses the SDK's cwd-filtered session listing and discards rows without the exact
active working-directory context; it neither merges those rows into the local
catalog nor persists them merely for display. The terminal receives
display-ready summaries with refresh-scoped opaque generation-and-slot keys,
while `backend/src/root.zig` privately resolves SDK IDs and calls
`Client.joinSession`. Joining fetches and projects the owned message history
before durable recency update, active-session commit, and previous-session
cleanup. Candidate tools and the system prompt are rebuilt for the recorded
working directory; any failure before commit disconnects the candidate and
leaves the current session and visible transcript active. A successful resume,
including a same-session selection, atomically replaces the terminal transcript
from the owned snapshot before reporting success.

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
availability and prompt policy consistent across every host. The session-level
allowlist is authoritative for model-visible capabilities, while the process
flag prevents built-in MCP servers from starting. The SDK declarations use the
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
- We accept a CLI launch flag alongside SDK session configuration because
  built-in MCP startup remains a process-level concern.
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
