# Slash model menu

Vivi opens a reusable slash-command menu from the composer and uses `/model`
to switch among authenticated Copilot models and discovered OMLX models
without restarting the TUI.

## Sub-features

- Typing `/` filters SDK-discovered slash commands.
- `/model` opens a model picker above the composer.
- Copilot default, authenticated Copilot models, and OMLX models share one
  picker with a current-model marker.
- Hosted and OMLX rows show context, output, and vision metadata when known.
- A successful switch keeps the visible transcript and explicitly reports that
  server-side conversation history was reset.
- A successful selection becomes the default in `~/.vivi/settings.json`; the
  helper's second PTY observes that persisted model as already active.
- The footer shows the active model at the far right and updates after a
  successful selection.

## How to get to it (user POV)

Start `vivi chat`, type `/model`, press Enter, move with Up or Down, and press
Enter to select a model. Escape dismisses either menu.

## Driving it with verify-vivi

```sh
.github/skills/verify-vivi/bin/verify-vivi chat-model-menu <run-id>
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-model-menu
```

The recipe filters for `gpt-5.6-sol` twice. Its VHS drive switches to and
persists that hosted model; its second `script` PTY confirms the new Vivi
instance already uses it, then sends a deterministic prompt and captures the
menu, persisted-default status, streamed answer, and shutdown.
Both runs share an isolated home under the evidence directory, with only the
Copilot credential directory linked through, so verification never modifies
the user's real `~/.vivi/settings.json`.

## Gotchas

- The authenticated Copilot account must expose `gpt-5.6-sol`.
- OMLX rows appear only when OMLX is running and exposes chat models.
- The new SDK session does not inherit server-side conversation history.
- The visible Vivi transcript remains on screen after switching.
