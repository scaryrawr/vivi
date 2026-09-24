# Vivi verification map

This directory verifies Vivi's launcher boundary and its delegated Copilot CLI
session.

## Baseline preconditions

- Build from the repository root with `bun run build`.
- Put Bun, `script`, GitHub CLI, and GitHub Copilot CLI on `PATH`.
- Authenticate GitHub CLI before credentialed drives.
- Hosted validation uses `gpt-6-luna` by default.
- Give every verification attempt a unique run ID.

## Driving conventions

- Start each session drive in its own `script` PTY.
- Use the compiled `dist/vivi` executable.
- Give each run its own isolated `VIVI_HOME`.
- Do not replace Copilot CLI with a mock for end-to-end proof.

## Proof and skip reporting

- Interactive proof requires a raw PTY transcript and explicit assertions.
- Noninteractive proof requires stdout and stderr.
- A streaming proof must assert a response token that was not present in the
  submitted prompt.
- Report authentication, network, or Copilot service failures as unmet
  preconditions rather than as verified application behavior.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph describing the
user-visible behavior. It then uses exactly four H2 sections in this order:

1. `Sub-features`
2. `How to get to it (user POV)`
3. `Driving it with verify-vivi`
4. `Gotchas`

## Features

- [CLI discovery](./cli-discovery.md) covers help, version, local model
  discovery, and native argument forwarding.
- [Streaming chat](./streaming-chat.md) covers a real Copilot PTY launched
  through Vivi.
- [Local models](./omlx-models.md) covers pre-start provider discovery and
  generated registry behavior.
