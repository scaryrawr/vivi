# Experimental Copilot SDK canvas contract

## Scope

Vivi exposes canvases to the optional macOS renderer described below, but not
to a CLI renderer. This note records the public typed canvas contract used by
the SDK-free domain in `backend/src/canvas.zig` and the production adapter in
`backend/src/root.zig`. Only `root.zig` imports `copilot_sdk` in production.
The standalone contract probe and adapter fixtures require neither credentials
nor a running Copilot CLI.

`build.zig.zon` remains the sole dependency pin. The tested revision is
`7695c34cb0ccfc4ec09aaadf91f29e4a12f86379`. The first public
`copilot-sdk-zig` revision containing this typed canvas surface is
`34283286ec9924b427a17efe571787669634268f` ("Add typed SDK extensibility
parity", 2026-09-13). That revision is synchronized to upstream
`github/copilot-sdk` commit `39c777fe7bf893ba5a4f8b710feeb2172d1d40f9`,
protocol version 3, and Copilot CLI `1.0.84-4`. The current Vivi pin retains
that contract.

## Public contract

The probe compiles these public root symbols:

- declarations and callbacks: `Canvas`, `CanvasAction`, `CanvasDeclaration`,
  and `CanvasProviderIdentity`;
- session state: `OpenCanvas`, `OpenCanvasRequest`, `OpenCanvasResult`,
  `OpenCanvasSnapshot`, and `InvokeCanvasActionRequest`;
- capability state: `Capability`, `CapabilityState`, and `CapabilitySet`;
- lifecycle configuration: `SessionFeatures`, `CreateExtensions`,
  `ResumeExtensions`, and `JoinExtensions`;
- operations: `Session.openCanvas`, `Session.closeCanvas`,
  `Session.invokeCanvasAction`, and `Session.snapshotOpenCanvases`;
- event variants: `session.canvas.registry_changed`, `.opened`, `.closed`,
  `.recorded`, `.removed`, and `.unavailable`.

Declarations contain an ID, display name, description, optional input schema,
open callback, optional close callback, and actions with optional input schemas.
The three-part runtime identity is `(extensionId, canvasId, instanceId)`.
Provider callbacks and lifecycle events carry all three values. Host open
requests may select an optional extension ID; close and action methods address
an existing instance ID.

`SessionFeatures.request_canvas_renderer` opts into a host renderer.
`request_extensions` separately requests extension discovery. A
`CanvasProviderIdentity` is lifecycle metadata beside the common features; it
does not prove that the runtime supplies a renderer.

Resume and extension-child join accept `open_canvases`. `null` means the caller
omitted restoration state, while an explicit empty slice means the caller
restores no canvases. Create has no `open_canvases` field. Snapshot results are
owned and expose `deinit`.

## Evidence and limits

| Observation | Evidence | Status |
| --- | --- | --- |
| Canvas declarations, callback shapes, validation, and renderer opt-ins compose | Public types plus local callback fixtures | Present |
| Open, close, action, and snapshot method signatures | Compile-time function assignments | Present |
| A dedicated reopen method | Public `Session` declarations | Absent; repeated `openCanvas` behavior is not specified |
| Registry event contains a typed `canvases` list | Public event parser and fixture | Present |
| Registry event declares snapshot or delta semantics | No operation, added, or removed field exists | Unknown; consumers must not infer either |
| Opened, closed, recorded, removed, and unavailable are distinct events | Public event parser and fixtures | Present |
| Lifecycle events correlate to operations with an operation/request ID | Public payload fields | Absent; only canvas identity is available |
| Runtime ordering or causality among recorded, removed, unavailable, opened, and method results | Public typed API | Unknown |
| Canvas capability defaults to `unknown` and fails closed | `CapabilitySet.state` and `supports` fixture | Present |
| Resume/join distinguish omitted, empty, and populated `openCanvases` | Public lifecycle types and fixtures | Present |
| Installed runtime advertises canvases and round-trips restored state | Not exercised by credential-free tests | Unknown |

Raw or generated JSON-RPC operations are not part of this evidence. JSON appears
only as controlled input to the public `copilot.session.parseEvent` boundary and
as schema/input values required by public canvas types.

## PR 2 decision

| Proposed PR 2 commitment | Decision | Required additional evidence |
| --- | --- | --- |
| SDK-free identity and declaration value types | Go | Preserve the three-part identity and optional schema/action fields |
| SDK-free capability state | Go | Preserve unknown, unsupported, and supported |
| SDK-free resume state that distinguishes omitted from empty | Go | Preserve optional `openCanvases` semantics |
| Model registry changes as snapshots | No-go | Public contract does not establish snapshot semantics |
| Model registry changes as deltas | No-go | Public contract exposes no delta operation |
| Correlate lifecycle events to host operations | No-go | No public operation/request ID exists |
| Define reopen, event ordering, or removal causality | No-go | Requires controlled live-runtime evidence |
| Add C ABI, WebView, CLI, or native UI behavior | No-go | Requires a concrete host contract and user-facing verification |

PR 2 implements only the approved SDK-free commitments. Registry reducer
inputs are explicitly tagged as replacement or incremental; a future adapter
must choose one only after SDK evidence establishes the meaning of its source
signal. Provider lifecycle signals remain uncorrelated with Vivi's monotonic
domain operation IDs and renderer generations.

A host may request another evidenced open operation for an already known
three-part key. The domain treats that as a new local open operation and
generation so stale renderer work can be rejected. It does not name or imply a
provider `reopen` operation, because no such SDK method is evidenced.

## PR 3 adapter decision

PR 3 wires the proven public typed surface without resolving unknown semantics:

- `ConversationOptions.request_extensions` and
  `request_canvas_renderer` independently map to the matching SDK feature
  fields and default to `false`.
- One root-private adapter and one SDK-free `canvas.State` belong to each
  active SDK session. Session replacement swaps that pair transactionally.
- Open, close, and action commands run on the existing serialized conversation
  worker. Their Vivi-owned request IDs are observable; internal operation
  tokens correlate only the direct result of the exact SDK method call.
- Opened, closed, unavailable, recorded, and removed events are validated and
  reduced independently. No lifecycle event is correlated by identity, timing,
  or arrival order.
- Repeating `openCanvas` with the same full key is another open operation. No
  provider reopen method is assumed.
- Registry declarations are fully bounded and validated, but production keeps
  the registry adapter mode unresolved and does not apply the list. Replacement
  mode exists only as a root-private fixture path until controlled runtime
  evidence proves snapshot semantics.
- `snapshotOpenCanvases` contributes positive opened observations only when a
  renderer was requested and capability is explicitly supported. Missing
  entries do not imply close or removal.
- Create has no restoration field. Join/resume always omits
  `open_canvases`; the domain projection remains unwired until inclusion and
  round-trip semantics are proven.
- Invalid or oversized data degrades the registry, operations, or an existing
  instance without closing chat. An invalid registry never replaces the last
  accepted registry.

No C ABI, Swift/WebView, terminal renderer, model-visible canvas tool, or
host-facing canvas UI is added by this adapter.

## PR 4 ABI decision

ABI v9 projects the SDK-free canvas domain without exposing SDK values. One
`canvas_mode` maps an explicit host opt-in to both internal SDK request flags;
it defaults to disabled, and every current native call site remains disabled.
One versioned `vivi_backend_perform_canvas` command accepts a full
extension/canvas/instance key plus role-specific open or action JSON spans and
returns a Vivi-local operation ID after copying all referenced bytes.

Canvas snapshots and operation completions use the existing `next_event`
queue. Declarations, actions, and instances are three flat caller-owned typed
arrays whose strings and JSON documents are spans into the event byte buffer.
The existing exact-capacity transaction applies across every old and new
destination: any shortage writes no payload, retains the pending event, and
an exact retry copies identical data before consuming it once. This ABI does
not add registry deltas, refresh, provider correlation, a reopen operation,
caller-authored generation preconditions, browser behavior, or rendering.
PR 5 remains the gate for native or CLI opt-in, decoding, and user-visible
canvas behavior.

## PR 5 macOS ownership decision

The macOS host decodes ABI v9 canvas events but keeps production canvas mode
disabled. `ViviConversationDriver` remains the sole C boundary and performs
one exact-capacity retry containing the byte, model, semantic-span, session,
transcript, canvas-declaration, canvas-action, and canvas-instance buffers.
Canvas events are accepted only after all counts, spans, UTF-8, role JSON,
enums, flags, reserved fields, optional-field combinations, ordering,
non-overlap, and duplicate constraints validate transactionally. A malformed
event follows the existing conversation failure-plus-close path.

Each `NativeChatStore` owns one `NativeCanvasStore`. It applies full snapshots,
retains declaration metadata for snapshot-present instances when discovery
disappears, correlates completions by the exact operation ID, and binds action
requests to the currently opened renderer generation. Conversation close and
successful session resume emit explicit host teardown before clearing canvas
work. App/window coordination does not own canvas state, so selection,
red-close, Dock reopen, and application resume preserve the existing
per-conversation ownership rules.

No renderer is introduced in PR 5.

## PR 6 macOS renderer decision

PR 6 adds a macOS-only renderer behind an explicit native-host configuration;
production remains disabled by default. The renderer consumes the typed ABI and
per-conversation `NativeCanvasStore`. It does not add terminal rendering,
process-global or workspace-keyed canvas state, a daemon, or a generic JSON
bridge.

Every renderer lease contains the full `(extensionId, canvasId, instanceId)`
key, backend renderer generation, and a native epoch that is never reused by
that conversation store. ABI v10 adds the expected backend generation to close
and action operations. The SDK-free state validates it immediately before
dispatch. Because the SDK's close and action methods accept only `instanceId`,
the domain detects active instance-ID collisions across full keys, makes every
collider unavailable, and refuses to call the SDK rather than choosing one.

The URL policy has two non-interchangeable origin classes:

- local extension servers may use HTTP or HTTPS with a required explicit port
  only when the literal host is exactly `localhost`, `127.0.0.1`, or `[::1]`;
- remote renderers require HTTPS and an exact origin injected by the native
  host; the remote allowlist is empty by default.

Authority is one exact normalized `(scheme, literal host, port)` per renderer.
It does not extend to localhost subdomains or wildcards, alternate numeric
spellings, DNS names that resolve to loopback, RFC1918, link-local, LAN, or
other private destinations. Top-level navigation, redirects, responses, and
subresources are constrained to that origin. WebSockets, new windows,
downloads, file and custom schemes, and cross-origin or cross-port loads are
denied. Each renderer uses a fresh nonpersistent website data store.

No `WKScriptMessageHandler`, user script, or action bridge is installed.
Provider page JavaScript has no native authority. This also bounds loopback
server and port reuse: stale callbacks fail the epoch/generation lease, old
views are destroyed, and replacement content cannot invoke the host. If a
future renderer needs authenticated local-server identity, cross-origin
assets, WebSockets, or actions, that requires new typed contract evidence and a
separate security review.

Renderer teardown is revocation-first and idempotent for canvas close,
generation replacement, successful resume, conversation close, backend
shutdown, protocol failure, app termination, and window presentation close.
Red-close preserves the logical per-conversation canvas state but releases all
WebKit presentation resources; reopening creates fresh native epochs.

## Synthesis decision

The probe uses one standalone semantic test module. It combines fixture-backed
event parsing with explicit present/absent/unknown documentation and local
declaration callbacks. A generic contract-manifest DSL was rejected
because it would duplicate Zig's type system; production adapters and fake
JSON-RPC transports were rejected because they would invent behavior outside
this evidence-gathering PR.
