# Streaming chat

Streaming chat lets a user type one prompt, submit it, see Vivi's response
arrive in the transcript, and regain the composer when the turn completes.

## Sub-features

- `chat-launch` opens the alternate-screen TUI and accented composer.
- `prompt-entry` accepts typed text through the libvaxis text input.
- `prompt-submit` adds the submitted text under `You:`.
- `response-stream` shows the responding state and Vivi output.
- `turn-ready` returns the context state to `Ready` after completion.

## How to get to it (user POV)

- Run `vivi chat`.
- Type a prompt in the bottom composer.
- Press Enter.

## Driving it with verify-vivi

Preconditions:

- `.github/skills/verify-vivi/bin/verify-vivi doctor` succeeds.
- A unique run ID is available.

- **Drive one turn.** Run
  `.github/skills/verify-vivi/bin/verify-vivi chat-streaming <run-id>`.
  The helper types
  `Return the uppercase spelling of vivi_stream_ok and nothing else.`, waits
  for streaming, and shuts down with Ctrl-C.
- **Observe the action.** Open `chat-streaming.contact-sheet.png`, then
  inspect individual PNGs under `chat-streaming.frames/` for the idle
  composer, typed prompt, `Responding...` state, `You` entry, `Vivi`
  response, restored `Ready` state, and shutdown state. Check that the
  composer accent is intact, labels are readable, and transcript/input regions
  never overlap.
- **Observe the result.** `chat-streaming.normalized.txt`, derived from the raw
  PTY transcript by removing terminal control sequences, contains
  `VIVI_STREAM_OK`, which was not present in the submitted prompt.
- **Record visual review.** Complete every item in
  `chat-streaming.visual-review.md`, set `status: pass`, name the inspected
  frame numbers, then run
  `.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-streaming`.
- **Proof.** `chat-streaming.assertions.txt` records exit status, expected
  response, transcript assertion, and frame-extraction assertions. Frame
  metadata, the contact sheet, extracted PNGs, and the completed visual review
  prove appearance and state progression.

## Gotchas

- This recipe calls the live Copilot service and may take longer than the
  fixed wait on a slow connection. Increase both 20-second waits in the helper
  together when diagnosing latency.
- Raw vaxis transcripts contain cursor-control sequences and may visually
  collapse spaces. Assert the no-space marker, not screen-line formatting.
- The first Ctrl-C may arrive after the response completes, which is valid
  cooperative shutdown. The second Ctrl-C is harmless if the shell is already
  idle.
- A retained GIF is for presentation only. It does not replace normalized text
  assertions or a passing frame review.
