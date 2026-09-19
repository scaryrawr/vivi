# Product

## Platform

Cross-platform command-line interface.

## Users

Vivi serves developers who want focused, project-aware Copilot conversations
in the terminal without managing a separate desktop application.

## Product Purpose

Vivi provides a responsive streaming chat, model selection, session resume,
workspace-aware tools, image attachments, and visible reasoning/tool activity
through one portable CLI.

## Capabilities and Constraints

- Zig is the authoritative implementation and the only production owner of the
  Copilot SDK.
- The libvaxis CLI owns terminal rendering, accessibility-oriented keyboard
  interaction, composer state, and transcript navigation.
- Backend modules own conversations, models, settings, tools, attachments,
  presentation semantics, and process lifecycle.
- Vivi does not ship native desktop or web application hosts.
- Workspace MCP tools remain fail-closed until an explicit approval boundary
  exists.

## Product Principles

- Keep the terminal experience compact, keyboard-first, and explicit about
  streaming, tools, failures, and recovery.
- Preserve project and session context without introducing another service or
  daemon.
- Prefer typed domain values and direct module boundaries over generic
  protocols.
- Prove behavior through the built CLI and real PTY interaction.
