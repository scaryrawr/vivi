# Product

## Platform

Cross-platform launcher and extension distribution for GitHub Copilot CLI.

## Users

Vivi serves developers who want local model discovery and an opinionated
Copilot environment without maintaining a separate agent client.

## Product Purpose

Vivi discovers local providers before session startup, installs coordinated
extensions, and launches Copilot with a persistent isolated profile.

## Capabilities and Constraints

- Bun is the authoritative launcher implementation.
- Copilot CLI owns terminal rendering, sessions, authentication, permissions,
  tools, MCP, skills, agents, and conversation lifecycle.
- Vivi owns local provider discovery, generated startup configuration, and its
  named extension directories.
- Vivi does not ship a second chat client, daemon, native host, or web host.

## Product Principles

- Add value before Copilot starts or through supported extension boundaries.
- Keep the launcher transparent: preserve arguments, stdio, signals, and exit
  status.
- Never overwrite Copilot-managed state.
- Prove behavior through the compiled launcher and the real Copilot CLI.
