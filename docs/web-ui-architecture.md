# Web presentation architecture

## Problem

Vivi needs a browser-testable presentation layer that can later run inside a
native webview without moving application or conversation authority out of
Zig. The boundary must preserve host-provided identity, ordering, selection,
lifecycle, transcript, and errors while avoiding SDK objects, C ABI memory,
generic JSON-RPC, or a daemon.

## Usage

Layer 1 composes the React application with a deterministic browser host:

```ts
const host = new MockViviHost(fixtures.multiple)
const connection = await host.connect()
root.render(<ViviApp host={connection} />)
```

Layer 2 replaces only the composition root:

```ts
const connection = await swiftViviHost.connect()
root.render(<ViviApp host={connection} />)
```

Components issue named `selectSession`, `createConversation`, and
`sendMessage` commands. They render the next host snapshot rather than
optimistically rewriting authoritative state.

## Shape

The public boundary has two levels:

1. `ViviHostPort` identifies protocol `vivi.host`, version `1`, and connects.
2. `ConnectedViviHost` publishes one atomic `HostSnapshot`, exposes connection
   state, and accepts the three named commands required by this slice.

`HostSnapshot` contains projects and sessions in host order plus the selected
session detail. Branded workspace paths, session IDs, transcript item IDs, and
submission IDs prevent titles or array positions from becoming identity.
Complete snapshots keep backend event sequencing, streaming assembly, and tool
correlation inside the host.

React keeps only ephemeral `UiState`: drafts, project disclosure, and
transcript disclosure. Its reducer and selectors are pure. Draft revisions
ensure a delayed accepted send cannot erase text typed after submission.
`ClientSubmissionId` lets a host deduplicate a retried send.

The deterministic `MockViviHost` implements the same port. It never uses
network access, credentials, wall-clock behavior, or SDK objects.

## Synthesis decision

The architecture arena selected the snapshot-port design as the base. It keeps
the authority boundary smaller and clearer than a frontend event reducer.
Submission revision and idempotency discipline were adapted from the
host-centric candidate; atomic connection and idempotent disconnect semantics
were adapted from the reducer-centric candidate. Backend-like delta events,
split application/conversation stores, and generic command envelopes were
rejected.

## Tradeoffs accepted

- We accept complete snapshot replacement in exchange for atomic host
  authority and a small frontend reducer.
- We accept runtime validation in the future native adapter in exchange for
  keeping transport payloads private.
- We accept an explicit V1 contract that requires deliberate V2 evolution in
  exchange for avoiding optional-field compatibility drift.
- We accept curated mock fixtures instead of a scenario scripting language in
  exchange for deterministic stories and browser evidence.

## Layer 2 host responsibilities

The Swift/WKWebView layer must:

- implement protocol `vivi.host`, version `1`;
- adapt existing Zig/C ABI operations and events into complete, monotonically
  newer `HostSnapshot` values;
- preserve project and session order and stable IDs across selection;
- keep launch-project identity distinct from any resumed active workspace;
- assign stable transcript item IDs and publish presentation-ready reasoning
  and tool activity;
- implement the three named commands and deduplicate `ClientSubmissionId`;
- keep WKWebView framing, script-message payloads, decoding, and validation
  private to the adapter;
- separate bridge failure from domain lifecycle/error state; and
- make connect/disconnect safe under remounts without changing conversation
  lifetime.

Layer 2 must not expose C ABI structs, SDK session objects, resume keys, or a
generic message bus to TypeScript.
