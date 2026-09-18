# terminal-browser v0.11.1 contract

## Scope

Vivi supports no production terminal canvas renderer yet. This contract-only
slice verifies the boundary required by a future optional CLI host without
adding a libvaxis drawer, panel, action bridge, script injection, clipboard
permission, or normal `vivi chat` integration.

The supported upstream release is exactly `terminal-browser v0.11.1`, annotated
tag `c53deaa437b704110ab3dc66e8d52bde04de5c1f`, peeled commit
`6d682348f4af469b56fa0fd8331b4eb967030893`. The local executable observed
during development was v0.8.1 and is not compatibility evidence. No upstream
v0.12.0 tag or release existed when this contract was recorded.

## Verified source contract

- `--version` prints exactly `terminal-browser v0.11.1`.
- `open --no-merge <url>` prevents adoption, while a foreground open remains
  attached to its daemon session connection.
- `new-tab <url> --browser <key>` returns a browser record with numeric
  `openedTab` and tab records.
- `ls --json` returns `{ self, browsers }`, including browser, process, socket,
  TTY, pane, viewport, and tab data. Enumeration may prune stale registry
  records and socket files, so production must not use it for ownership.
- Targeted close uses
  `action --browser <key> --tab <id> -- tab close`.
- Closing the final tab creates a replacement tab. There is no public
  per-browser close command.
- `shutdown` is global and forbidden.
- App-mode, preload, and main-script flags were removed and fail in v0.11.1.

The deterministic fixture suite rejects malformed UTF-8/JSON, every unknown
field, unsupported shapes, duplicate identifiers, excessive output, timeout,
crash, and nonzero exit. All subprocesses use fixed argv arrays, bounded
stdout/stderr, and a timeout over the entire process lifetime.

## Ownership decision

**Probe-only no-go.** Upstream source shows that an attached foreground client
may own one daemon session connection, but Vivi has not yet retained real
terminal evidence proving a bounded readiness signal and complete cleanup of
that session's browser, pane, socket, and registry resources without global
enumeration. Targeted tab close is insufficient because it leaves a replacement
tab and browser.

The opt-in verifier:

```sh
zig build verify-terminal-browser-real \
  -Dterminal-browser=/absolute/path/to/v0.11.1/terminal-browser
```

validates the trusted absolute executable and exact version, then emits a
bounded JSON no-go report. The downloaded Darwin arm64 v0.11.1 artifact matched
the release SHA-256
`9b21729e47bcc07e969913223705ce1ae5bcaa8e49094d6c9705c4cca8311d90`;
the verifier confirmed its exact version and non-mutating `open`, `new-tab`,
`ls`, and `action` help contracts. It intentionally does not run those stateful
commands or `shutdown` against a user's shared installation.

A later PR may add a private process-owned adapter only after isolated evidence
proves readiness, exact retained-child ownership, complete cleanup, sibling
isolation, partial-start rollback, and origin containment no broader than the
native host. Unknown capability remains unavailable.

Windows is compilation-only for this contract because v0.11.1 publishes no
upstream Windows artifact.
