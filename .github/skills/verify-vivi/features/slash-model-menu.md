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

## How to get to it (user POV)

Start `vivi chat`, type `/model`, press Enter, move with Up or Down, and press
Enter to select a model. Escape dismisses either menu.

## Driving it with verify-vivi

```sh
.github/skills/verify-vivi/bin/verify-vivi chat-model-menu <run-id>
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-model-menu
```

The recipe filters for `gpt-5.6-sol`, switches to that explicit hosted model,
sends a deterministic prompt through the replacement session, and captures
the menu, picker, switch status, streamed answer, and shutdown.

## Gotchas

- The authenticated Copilot account must expose `gpt-5.6-sol`.
- OMLX rows appear only when OMLX is running and exposes chat models.
- The new SDK session does not inherit server-side conversation history.
- The visible Vivi transcript remains on screen after switching.
