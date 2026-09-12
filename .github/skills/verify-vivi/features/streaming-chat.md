# Streaming chat

Streaming chat lets a user submit prompts, see Vivi's response arrive in the
transcript, steer the active turn, queue a follow-up, and keep composing until
the session returns to the ready state.

## Sub-features

- `chat-launch` opens the alternate-screen TUI and accented composer.
- `prompt-entry` accepts typed text through the libvaxis text input.
- `prompt-submit` adds the submitted text under `You:`.
- `response-stream` shows the responding state and Vivi output.
- `reasoning-stream` shows model reasoning as a dim, italic `Thinking` entry
  before the corresponding Vivi response.
- `tool-activity` shows compact running, successful, or failed rows for
  `read`, `bash`, `edit`, and `write` calls.
- `transcript-scroll` uses Page Up/Page Down to read chat history after it
  grows beyond the visible transcript.
- `transcript-select-copy` lets the terminal handle text selection and copying
  from the transcript.
- `response-steer` keeps the composer active and sends Enter submissions into
  the current turn.
- `response-queue` sends Ctrl+Enter submissions as FIFO follow-up turns.
- `turn-ready` returns the context state to `Ready` after completion.

## How to get to it (user POV)

- Run `vivi chat`.
- Type a prompt in the bottom composer.
- Press Enter.
- While Vivi is responding, type a correction and press Enter to steer.
- While Vivi is responding, type a follow-up and press Ctrl+Enter to queue it.
- Use Page Up/Page Down to read older or newer messages.
- Drag over transcript text with the terminal's normal selection gesture, then
  use the terminal's copy command.
- Models that expose reasoning stream it into a muted `Thinking` transcript
  entry while the final response remains under `Vivi`.

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
- **Drive streaming input.** Run
  `.github/skills/verify-vivi/bin/verify-vivi chat-streaming-input <run-id>`.
  The helper starts a delayed response, sends an Enter-delivered steering
  correction while it is active, then starts another delayed response and
  sends a Ctrl+Enter queued follow-up.
- **Observe streaming input.** Confirm the composer remains editable while the
  context reads `Responding...`, the footer shows `Enter steer` and
  `Ctrl+Enter queue`, both submitted messages appear in the transcript, and a
  compact `Run sleep 6` tool row appears without replacing the Vivi response.
  The normalized transcript must contain `VIVI_STEER_OK`,
  `VIVI_QUEUE_FIRST`, and `VIVI_QUEUE_OK`.
- **Record streaming-input review.** Complete
  `chat-streaming-input.visual-review.md`, set `status: pass`, name the
  inspected frame numbers, then run
  `.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-streaming-input`.

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
- Steering is best effort. If the active turn reaches idle before Vivi forwards
  the message, Copilot processes it as the next queued turn.
