# Chat shutdown

Chat shutdown lets a user leave an idle conversation with Ctrl-C and provides
a second-Ctrl-C escape when cooperative shutdown cannot pass a blocked SDK
event boundary.

## Sub-features

- `idle-stop` closes an idle chat after one Ctrl-C.
- `stopping-notice` shows the explicit stopping state during cooperative stop.
- `forced-stop` restores the terminal and exits with status 130 after a second
  Ctrl-C while still stopping.

## How to get to it (user POV)

- Run `vivi chat` and press Ctrl-C while the composer is idle.
- During a blocked response, press Ctrl-C once, then press it again only after
  the UI shows `Stopping...`.

## Driving it with verify-vivi

Preconditions:

- `.github/skills/verify-vivi/bin/verify-vivi doctor` succeeds.
- A unique run ID is available.

- **Drive idle shutdown.** Run
  `.github/skills/verify-vivi/bin/verify-vivi chat-shutdown <run-id>`.
  VHS captures the TUI, waits for readiness, presses Ctrl-C, and extracts the
  visual proof frames.
- **Inspect frames.** Review `chat-shutdown.contact-sheet.png` and the
  individual frames for a readable idle layout, intact composer accent, and a
  clean return to the shell without stale alternate-screen content. Complete
  `chat-shutdown.visual-review.md`, then run
  `.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-shutdown`.
- **Proof.** Retain `chat-shutdown.assertions.txt` together with the contact
  sheet, extracted frames, metadata, and completed visual review.
- **Forced escape.** Verify manually only when a real response remains blocked:
  press Ctrl-C, observe
  `Stopping... press Ctrl-C again to force exit.`, then press Ctrl-C again and
  record exit status `130`.

## Gotchas

- Do not manufacture a blocked Copilot transport solely to exercise forced
  exit; that would test a synthetic failure rather than the user path.
- A first Ctrl-C during an active response is cooperative and may wait for the
  next SDK event.
- The forced path intentionally skips backend cleanup because the process is
  exiting; use it only after the visible stopping state.
