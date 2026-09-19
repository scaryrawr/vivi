# Canvas domain

## Problem

Vivi needs a canvas model that can accept extension declarations and track
canvas instances before any SDK adapter or renderer is enabled. The model must
remain useful to future native and web hosts without making those hosts
authoritative for declaration validation, operation correlation, cancellation,
or recovery.

The difficult invariant is lifecycle truth. An instance in `opening` or
`closing` must always own the exact operation token and effect that can finish
that transition. Allocation failure, effect publication failure, cancellation,
or a stale completion must not strand an instance in a transitional state.

## Ownership

`backend/src/canvas.zig` is the complete renderer-neutral domain:

- bounded `ExtensionId`, `CanvasId`, `ActionName`, and `InstanceId` values;
- role-specific schema, open-input, action-input, and action-result JSON
  documents;
- owned canvas and action declarations;
- replacement and incremental registry updates;
- instance lifecycle, action operations, recording state, and degradation;
- deterministic snapshots and resume projection.

`backend/src/root.zig` only re-exports the module today. A later SDK adapter
belongs in `root.zig`, which remains the only production module allowed to
import `copilot_sdk`. That adapter will translate SDK values into the typed
canvas inputs and execute the typed effects.

Native and web hosts are later consumers of snapshots. They do not mint
operation tokens, decide whether completions are stale, mutate the registry, or
interpret pending lifecycle state. The C ABI, Swift/AppKit/WKWebView, CLI UI,
and HostPort transport are intentionally unchanged.

## Typed boundaries

Identity values are nominal, fixed-capacity UTF-8 values. Construction rejects
empty, invalid, or over-limit input before it reaches domain state. Composite
keys enforce an aggregate byte limit, and every public operation validates its
borrowed key before lookup, capacity, or allocation decisions. Replacement
registry size and incremental registry operation count are bounded
independently, so repeated upserts or removals cannot bypass the final-size
limit. The registry also has an aggregate owned-byte budget that is projected
with overflow-safe arithmetic and enforced before any registry clone or
declaration allocation, so bounded per-document limits cannot be multiplied
into an unbounded registry.

JSON remains at the extension boundary, but there is no generic JSON envelope:

| Type | Accepted root |
| --- | --- |
| `SchemaDocument` | object or boolean |
| `OpenInputDocument` | object or null |
| `ActionInputDocument` | object or null |
| `ActionResultDocument` | any JSON value |

All document types enforce byte, UTF-8, depth, and node limits and own their
validated bytes. Their nominal types prevent an action result from being used
as an open input without an explicit adapter decision.

## Lifecycle transaction

Callers submit a complete operation such as `open`, `close`, `invokeAction`, or
`cancel`. Each operation follows one ordering:

1. validate the request and current state;
2. allocate and own the complete candidate replacement;
3. construct the exact canvas effects from that candidate;
4. ask `EffectPublisher.publishAtomic` to copy and accept all effects;
5. commit the candidate with allocation-free swaps.

Publication success means every effect was accepted; failure means none was
accepted. A publisher must not call back into the same domain while an
operation is in flight; every mutating entry point rejects reentrancy with
`ReentrantDomainCall` rather than letting a nested mutation be lost or applied
to a stale index.

This ordering is the transaction boundary. No authoritative state changes
before all fallible preparation and publication succeeds, and no fallible work
occurs after publication. A failed replacement open therefore retains the
original `opening` token, rather than deleting it and leaving an unfinishable
state.

An open request may replace an existing `opening` request atomically, but it
does not replace an `opened` or `closing` instance. Those requests fail with a
typed error so a live renderer cannot be discarded without an explicit close
or cancellation transition.

The runtime shape encodes the invariant:

```text
closed
opening { token, owned open input }
opened { generation, renderer-neutral metadata }
closing { token, owned prior opened state }
unavailable
```

Pending actions likewise own their token, action identity, and input. There is
no separate pending-token store that can drift away from lifecycle state.
Completions match the full token: operation ID, instance generation, and
operation kind. Missing or mismatched tokens are stale no-ops.

The instance bound applies to active or recorded state, not every key ever
observed. When capacity is full, a new key may transactionally replace the
oldest stable unrecorded `closed` or `unavailable` entry; live and recorded
instances are never evicted.

Cancellation publishes the cancellation effect before committing a stable
state:

- opening becomes closed;
- closing restores its prior opened state;
- a pending action is removed without changing the instance lifecycle.

Provider or declaration loss uses `markUnavailable`, which atomically cancels
all work and publishes teardown for any live renderer before committing
`unavailable`. The caller supplies the reason, so snapshots distinguish a
removed declaration from a lost provider for both known and previously unseen
instance keys. Registry updates do not guess whether a removed declaration
means an already-open instance was closed by its provider; a future SDK
adapter must apply the corresponding typed availability signal explicitly.

## Snapshots and resume

`snapshot` returns owned declarations and renderer-neutral instance metadata.
Hosts cannot retain mutable pointers into the domain.

Recording state is independent of runtime state. `resumeProjection` includes
only recorded identity, title, and open input. It excludes runtime tokens,
generations, location, status, pending actions, and other process-local facts.
The domain's own capability state is the single authority: unknown or
unsupported capability produces an omitted projection, while supported
capability with no recorded canvases produces an explicit empty list.

Shutdown uses the same transaction rule as other cancellations. A publication
failure leaves every pending operation live and makes shutdown retryable. A
successful shutdown publishes explicit teardown effects for opened renderers,
stabilizes all instances, clears pending actions, and is idempotent.
Teardown effects carry the renderer generation; adapters must ignore a
teardown whose generation no longer matches the renderer currently bound to
that instance key.

`Domain.deinit` is a checked lifecycle boundary, not an emergency escape:
callers must complete `shutdown` first, and destruction is rejected during a
publisher callback. Internal tests use a private unchecked cleanup helper only
to release intentionally partial fixtures.

## Later adapters

An SDK adapter may be added only when the pinned SDK exposes the required
canvas contract. It must provide the all-or-none effect acceptance guarantee
and echo domain tokens with completions. SDK declarations, callbacks, JSON-RPC
types, and transport errors stay in `root.zig`.

A WebView or native renderer may be added only with a typed host binding. It
consumes snapshots and translates domain metadata into presentation state.
This domain does not define HTML, URLs, JavaScript messages, a generic JSON
bridge, or a renderer document grammar.

## Verification

Direct module tests use fixture declarations and a scripted atomic publisher.
They cover role validation, registry semantics, normal lifecycle transitions,
stale completions, scoped recording, resume projection, and idempotent
shutdown. Allocation-failure sweeps and publication-failure fixtures assert
that the previous token and lifecycle remain intact on every fallible path.

Run:

```sh
zig test backend/src/canvas.zig
zig build test
```
