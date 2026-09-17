# Experimental Copilot SDK canvas contract

## Scope

Vivi does not expose or implement canvases. This note records the public typed
canvas contract available to a future SDK-free domain design. The accompanying
probe imports `copilot_sdk` only from a standalone test root; it adds no canvas
types to `backend/src/root.zig`, the C ABI, CLI, or native hosts, and it neither
starts Copilot CLI nor requires credentials.

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

## Synthesis decision

The probe uses one standalone semantic test module. It combines fixture-backed
event parsing with explicit present/absent/unknown documentation and local
declaration callbacks. A generic contract-manifest DSL was rejected
because it would duplicate Zig's type system; production adapters and fake
JSON-RPC transports were rejected because they would invent behavior outside
this evidence-gathering PR.
