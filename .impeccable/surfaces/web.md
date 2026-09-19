---
version: 1
slug: "web"
primary_target: "web"
related_targets: []
---

## Scope and mode

Standalone `web/` application shell in Operate mode. Layer 1 is browser-testable
and does not alter the shipping macOS window.

## Audience, job, and task

Developers move among project-bound Copilot conversations, inspect answers,
reasoning, tools, lifecycle, and errors, then send the next instruction without
losing ordering or selection context.

## Content and constraints

Use deterministic realistic fixtures. Host identity, order, selection,
lifecycle, transcript, and errors are authoritative. React owns presentation
and ephemeral draft/disclosure/focus only. System fonts and local assets; strict
WKWebView CSP; keyboard and reduced-motion support.

## Chosen direction

Compact native productivity split view: restrained graphite materials, one blue
selection accent, full-row project disclosures, unified live/saved sessions,
readable transcript, and anchored multiline composer. No traffic lights,
browser chrome, dashboard cards, ordinals, or separate history.

## Memorable moment

Selection moves cleanly among the top, middle, and bottom sessions while every
row stays fixed in host order.

## Unresolved

Layer 2 decides the private WKWebView transport framing and native workspace
chooser behavior while implementing the published V1 port.
