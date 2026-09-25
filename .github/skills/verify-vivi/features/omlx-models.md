# Local models

Local model support discovers provider metadata before Copilot starts and
writes it to a private process-scoped registry.

## Sub-features

- `provider-probing` discovers Ollama, LM Studio, OMLX, OSaurus, and GenieX.
- `model-list` prints provider-qualified model IDs and token limits.
- `vision-detection` marks OMLX VLM models as vision capable.
- `startup-registration` exposes the registry before Copilot creates a session.

## How to get to it (user POV)

- Start any supported local provider and load at least one model.
- Run `vivi models`.
- Run `vivi --model <provider>/<model-id>`.

## Driving it with verify-vivi

- Run `./dist/vivi models` and retain stdout showing `context=`, `output=`,
  and `vision=` fields.
- Unit tests cover provider payload normalization and unavailable-server
  behavior.
- A launcher smoke test should inspect `COPILOT_PROVIDERS_CONFIG` before the
  fake child exits and assert that the registry is removed afterward.

## Gotchas

- Provider failures are ignored so hosted Copilot remains usable.
- Missing token metadata uses 131072 context tokens and 32768 output tokens.
