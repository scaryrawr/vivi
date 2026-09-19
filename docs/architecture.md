# Architecture

## Shape

Vivi is a cross-platform Zig CLI with one authoritative backend. The CLI
imports `vivi_backend` directly; there is no native host, web presentation,
C ABI, daemon, or generic transport layer.

`backend/src/root.zig` is the only production module allowed to import
`copilot_sdk`. It adapts SDK models, sessions, commands, permissions, and tool
events into owned domain values. SDK-free backend modules own conversation
lifecycle, tools, settings, models, file picking, attachments, presentation,
and PTY management.

The Bun and TypeScript packages are a transitional migration scaffold. Zig
remains the production CLI. Install and check the scaffold with
`bun install --frozen-lockfile` and `bun run check`. Run `bun run probe:runtime`
only when Copilot credentials and a running Copilot CLI are available.

`cli/src/main.zig` owns command parsing and process setup.
`cli/src/chat.zig` owns the libvaxis event loop, transcript, composer, menus,
questions, tool disclosure, scrolling, and responsive terminal layout.

## Conversation boundary

`backend/src/conversation.zig` owns the worker, one-command mailbox, event
queue, and lifecycle state. The libvaxis loop receives a payload-free wake,
then transfers owned events from the backend into its private UI state. SDK
objects and allocator lifetimes never cross onto the terminal UI thread.

Model replacement and session resume are transactional: Vivi prepares the
candidate session and history before replacing the active session. Failures
leave the current session and transcript intact.

## Tools and permissions

`backend/src/tools.zig` owns SDK-free `read`, `bash`, `edit`, and `write`
behavior. `backend/src/root.zig` owns their SDK declarations and translates
tool results, including typed image content.

Ambient workspace configuration and project skills are discoverable. MCP
permission requests remain denied until the CLI has an explicit user approval
boundary. Built-in or ambient server names are not trusted as provenance.

## Platform support

The CLI builds for Windows, Linux, and macOS. Platform-specific code is limited
to services required by the terminal product:

- macOS clipboard image reads use AppKit.
- Linux clipboard image reads use `wl-paste` or `xclip`.
- Windows clipboard image reads use PowerShell.
- POSIX async shells use `openpty`; Windows uses ConPTY.

These adapters remain private to the CLI/backend and do not imply a desktop
application host.

## Persistence

Vivi stores settings in `~/.vivi/settings.json` and launches Copilot with
`~/.vivi/copilot/` as its private runtime directory. Copilot CLI remains the
authority for session storage. Settings writes are versioned, locked, and
atomically replaced.

## Verification

`zig build test` covers backend and CLI behavior without credentials.
`./scripts/check.sh` adds formatting, CLI smoke checks, and Linux/Windows
cross-builds. User-visible TUI behavior is verified through the installed
`zig-out/bin/vivi` executable in isolated PTY sessions.
