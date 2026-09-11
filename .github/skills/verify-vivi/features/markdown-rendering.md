# Markdown rendering

Markdown rendering presents assistant responses as styled terminal content
without changing the raw conversation text.

## Sub-features

- Headings render without source markers and remain visually distinct.
- Bold, italic, strikethrough, inline code, and safe links use terminal styles.
- Fenced Zig, shell, and JSON snippets use tree-sitter syntax colors.
- Lists, task items, blockquotes, and fenced code retain readable structure.
- Prose wraps at word boundaries, with grapheme fallback for oversized words.
- Wide GFM tables render as grids; narrow tables render as labeled fields.
- Incomplete streamed Markdown remains visible until its structure is complete.
- Successful `read` tool output for Markdown files uses the same rich renderer
  when the tool row is expanded; failed reads remain literal error output.

## How to get to it (user POV)

- Run `vivi chat`.
- Ask Vivi for a response containing Markdown formatting and a table.
- Resize the terminal to confirm the content remains readable.

## Driving it with verify-vivi

- Run `.github/skills/verify-vivi/bin/verify-vivi doctor`.
- Run `.github/skills/verify-vivi/bin/verify-vivi chat-markdown <run-id>`.
- Run
  `.github/skills/verify-vivi/bin/verify-vivi chat-markdown-read <run-id>` to
  read `README.md`, focus the completed tool with F6, and expand it.
- Open `chat-markdown.contact-sheet.png` and inspect individual frames under
  `chat-markdown.frames/`.
- Confirm `Render Test` appears as a heading, bold and inline-code styles are
  visibly distinct, the Zig code block uses multiple syntax colors, and the
  Feature/Status table uses aligned borders rather than raw Markdown pipes.
- Complete `chat-markdown.visual-review.md`, set `status: pass`, record the
  inspected frame numbers, and run
  `.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-markdown`.
- For the read-tool drive, confirm the expanded output shows rendered
  `Requirements` and `Build the CLI and backend` headings, list bullets, and
  indented code rather than raw Markdown markers. Complete
  `chat-markdown-read.visual-review.md`, then run
  `.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-markdown-read`.

## Gotchas

- The Copilot response is live and may vary slightly while preserving the
  requested structure.
- Styles require visual frame review; normalized PTY text cannot prove bold,
  italic, backgrounds, or table alignment.
- A table may use the stacked fallback when the transcript viewport is narrow.
