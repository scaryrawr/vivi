# OMLX models

OMLX model support discovers live model metadata, reports token limits, and
starts a Vivi chat with the selected local model.

## Sub-features

- `model-list` prints qualified OMLX model IDs and display names.
- `context-detection` reports `max_context_window` as the model context limit.
- `output-detection` reports `max_tokens` as the maximum output limit.
- `vision-detection` marks OMLX `vlm` models as vision capable.
- `local-chat` creates the Copilot SDK session with the selected OMLX provider.

## How to get to it (user POV)

- Start OMLX and load at least one language or vision-language model.
- Run `vivi models`.
- Run `vivi chat --model omlx/<model-id>`.
- Set `OMLX_BASE_URL` or `OMLX_API_KEY` when the defaults do not apply.

## Driving it with verify-vivi

Preconditions:

- OMLX is listening at `OMLX_BASE_URL` or `http://localhost:8000`.
- At least one model appears in `/v1/models/status`.
- `verify-vivi doctor` succeeds.

- Run `./zig-out/bin/vivi models` and retain stdout showing the selected test
  model's `context=`, `output=`, and `vision=` fields.
- Start `./zig-out/bin/vivi chat --model omlx/<model-id>` in a fresh `script`
  PTY, submit a deterministic prompt, and retain the terminal log.
- Confirm the distinct expected response appears and the TUI returns to
  `Ready` before cooperative shutdown.

## Gotchas

- The standard `chat-streaming` recipe intentionally exercises hosted
  Copilot. Use a separate run directory for an OMLX-backed manual drive.
- OMLX discovery failures are startup failures; Vivi does not silently fall
  back to a hosted model.
- Missing token metadata uses 131072 context tokens and 32768 output tokens.
