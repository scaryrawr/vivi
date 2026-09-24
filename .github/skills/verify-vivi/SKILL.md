# Verify Vivi

Drive the compiled Vivi launcher as a user would. Vivi delegates the terminal
experience to GitHub Copilot CLI, so verification focuses on the launcher
boundary rather than a Vivi-owned TUI.

## Build

```sh
bun run build
```

The executable is `./dist/vivi`.

## Health check

```sh
.github/skills/verify-vivi/bin/verify-vivi doctor
```

The doctor builds Vivi, checks Bun and Copilot CLI, launches a credentialed
noninteractive prompt through Vivi, verifies the exact response
`VIVI_DOCTOR_OK`, and confirms both bundled extensions were materialized.

## Drives

```sh
.github/skills/verify-vivi/bin/verify-vivi cli-discovery <run-id>
.github/skills/verify-vivi/bin/verify-vivi chat-streaming <run-id>
```

Run IDs may contain only letters, digits, dots, underscores, and hyphens.
Evidence is written under `.verify/vivi/<run-id>/`.

`chat-streaming` uses `script` to launch the compiled Vivi executable in a
real PTY, submits a lowercase marker prompt, and asserts the distinct uppercase
response. It uses an isolated `VIVI_HOME` and removes that profile after the
drive so credentials and runtime state are not retained as evidence.

## Authentication

Credentialed drives require `gh auth token`. The helper passes the token to the
isolated Copilot process through `GH_TOKEN` and `GITHUB_TOKEN` without writing
it to evidence.

Use `VIVI_VALIDATION_MODEL=<model-id>` to override the default hosted
validation model.

## Evidence

Keep stdout, stderr, PTY logs, assertions, and exit statuses. A valid streaming
assertion must check a response token that is absent from the submitted prompt.
Do not replace Copilot CLI with a mock for end-to-end proof.
