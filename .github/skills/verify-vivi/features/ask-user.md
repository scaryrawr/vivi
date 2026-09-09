# Ask-user prompt

Vivi presents Copilot's interactive question as a distinct transcript entry,
keeps numbered choices readable, accepts a one-based numeric answer, and
continues the same streamed response with the selected choice.

## Sub-features

- A question has its own `Question` transcript label.
- Numbered choices are indented without status bullets.
- The composer remains active while the context state says `Answer required`.
- The footer tells the user that either a number or choice text is accepted.
- A numeric answer is resolved to the corresponding choice before Copilot
  continues.

## How to get to it (user POV)

1. Run `vivi chat`.
2. Ask Vivi to use `ask_user` with two or more choices.
3. Wait for the `Question` entry and `Answer required` state.
4. Select a choice with the arrow keys and press Enter.
5. Confirm the chosen text appears as the user's answer and the response
   continues.

## Driving it with verify-vivi

Run:

```sh
.github/skills/verify-vivi/bin/verify-vivi chat-ask-user <run-id>
```

The recipe uses the hosted Copilot model, requests `Alpha` and `Beta`, moves
the selection to `Beta`, and requires the final answer to contain
`ANSWER Beta`.

## Gotchas

- The Copilot service must choose to call `ask_user`; a service-side refusal is
  an unmet test precondition.
- The question may arrive after reasoning text, so inspect the state transition
  rather than assuming a fixed frame number.
- Free-form input remains available through the composer when the request
  permits it.
