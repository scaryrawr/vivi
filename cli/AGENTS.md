# CLI Renderer Guidance

Keep the interactive chat on the process `init.gpa`; do not replace its
allocator to hide DebugAllocator growth. Route only frame-owned projection
output, layout planning, and parser scratch through `RenderMemory`.

Vaxis screen cells shallow-borrow rendered grapheme and link slices. Recycle
renderer arenas only after a full `root.clear()` ends those borrows.
Composer-only renders must preserve the active frame. Transcript residency,
highlight caches, tool data, UI state, backend state, and conversation state
remain on the process allocator.

Consume the final `ToolStarted.input_presentation` and
`ToolFinished.output_presentation` values produced by the backend. Do not
reclassify tool output, infer languages, parse source, or perform strict
fallback in the CLI. Terminal argument labels, wrapping, Vaxis styles, and
Markdown layout remain CLI-owned. Map backend Bash input spans into the
terminal-formatted argument display, and measure only the final presentation
bytes.

Markdown fenced code uses `vivi_backend.presentCodeFragment`; the backend owns
language aliases and Tree-sitter tokens while the CLI owns its highlight cache.
