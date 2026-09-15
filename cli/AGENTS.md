# CLI Renderer Guidance

Keep the interactive chat on the process `init.gpa`; do not replace its
allocator to hide DebugAllocator growth. Route only frame-owned projection
output, layout planning, and parser scratch through `RenderMemory`.

Vaxis screen cells shallow-borrow rendered grapheme and link slices. Recycle
renderer arenas only after a full `root.clear()` ends those borrows.
Composer-only renders must preserve the active frame. Transcript residency,
highlight caches, tool data, UI state, backend state, and conversation state
remain on the process allocator.

Sanitize tool output with `tool_renderer.renderOutput` or `renderMarkdown`
before Tree-sitter parses it. Highlight spans must index `output_display`, not
the raw payload. Treat `read` results with an `offset` or `limit` as fragments
and use tolerant highlighting. Reserve complete parsing for full-file or
homogeneous command output, and reject oversized complete sources before
truncation.
