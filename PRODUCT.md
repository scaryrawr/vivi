# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Users

Vivi serves developers who use Copilot while working inside a local project and
want a focused desktop conversation surface that preserves project and session
context without making the interface itself another system to manage.

## Product Purpose

Vivi provides streaming, project-aware Copilot conversations through native
desktop applications and a command-line interface while keeping one
authoritative Zig domain implementation. Success means users can move among
projects and conversations, understand ongoing model and tool activity, and
send the next instruction without losing context or fighting presentation
state.

## Positioning

Vivi separates a cross-platform Zig conversation core from platform-owned
presentation. Native hosts adapt the same domain semantics to their operating
system instead of sharing widgets, view models, SDK objects, or a generic
remote protocol.

## Operating Context

Users work with several local repositories, often keep more than one
conversation per project, resume saved sessions, inspect streamed answers,
reasoning, and tool activity, and compose keyboard-first follow-up messages.
The macOS application is currently SwiftUI/AppKit; the authorized migration
introduces a browser-testable React surface intended for a future WKWebView
host without changing the shipping window in its first layer.

## Capabilities and Constraints

- Zig remains the authoritative backend and the only production owner of the
  Copilot SDK.
- Frontends consume explicit named domain commands and events through stable
  host boundaries; SDK objects, Zig-owned memory, generic JSON-RPC, and daemon
  protocols do not cross into presentation.
- Host state owns project/session identity, ordering, selection, lifecycle,
  transcript content, streaming state, and errors.
- The web presentation owns rendering, accessibility, keyboard interaction,
  disclosure state, composer draft state, and other ephemeral UI concerns.
- Layer 1 is standalone and browser-testable. It does not add WKWebView wiring,
  script message handlers, a feature flag, or a production cutover.
- Production assets are local and the bundle must support a strict WKWebView
  content security policy without remote fonts, remote network dependencies,
  or eval.

## Brand Commitments

The product name is Vivi. The application should feel like a high-quality
macOS productivity tool: restrained, compact, system-like, keyboard-first, and
clear about hierarchy and state. Existing SwiftUI visuals are an anti-reference
for the replacement surface; current product behavior and terminology remain
evidence.

## Evidence on Hand

The repository contains the authoritative Zig backend, stable C ABI, CLI, the
shipping SwiftUI/AppKit host, native tests, and realistic transcript semantics.
There are no approved remote brand assets, customer claims, benchmarks, or
marketing proof to invent.

## Product Principles

- Keep domain authority in Zig and presentation authority in each host.
- Preserve host order and identity; never let selection rewrite the model.
- Make streaming, reasoning, tools, failures, and recovery legible without
  turning activity into visual noise.
- Prefer compact, direct interactions that reward keyboard fluency.
- Prove behavior through deterministic fixtures and user-visible interaction.

## Accessibility & Inclusion

The desktop experience must support keyboard-only operation, visible focus,
semantic controls and structure, reduced motion, sufficient contrast, and
labels that communicate project, session, lifecycle, and error state without
depending on color or ordinal badges.
