# Composer image attachments

Vivi can snapshot a clipboard image into the composer, show its private
temporary-file token, and submit the immutable image with the prompt through
the active workspace's isolated Copilot session.

## Sub-features

- macOS AppKit clipboard acquisition and private temporary PNG ownership
- attachment-only or text-plus-image submission through the hosted Copilot path
- workspace instruction discovery from the active conversation directory
- Copilot runtime isolation under the run-local `.vivi/copilot` directory

## How to get to it (user POV)

Copy an image, start `vivi chat` in the intended workspace with a
vision-capable model, and press Ctrl-V or Alt-V. Vivi inserts a quoted private
PNG path into the composer. Submit it alone or add prompt text before pressing
Enter.

## Driving it with verify-vivi

On macOS, run:

```sh
VIVI_VHS=/path/to/working/vhs \
  .github/skills/verify-vivi/bin/verify-vivi \
  chat-attachments <run-id>
```

The recipe creates a blue PNG, writes it to the AppKit pasteboard, starts Vivi
from a fixture workspace, and drives both VHS and `script` PTYs with a run-local
`HOME` and `TMPDIR`. It injects the authenticated GitHub token rather than
copying or symlinking `.copilot`. The assertions require the attachment token,
the hosted response, workspace instruction marker, private
`.vivi/copilot` directory, absent `.copilot`, extracted frames, and contact
sheet.

## Gotchas

- The recipe is macOS-only because it prepares the real AppKit pasteboard.
- Use a VHS release that actually writes its declared GIF; 0.12.0 is known to
  exit successfully without output.
- The selected model must support images. Override it with
  `VIVI_ATTACHMENT_MODEL` when the default `copilot/gpt-5.6-luna` validation
  model is unavailable or a specific vision model is under test.
- A terminal may reserve Ctrl-V; Alt-V remains the manual fallback.
