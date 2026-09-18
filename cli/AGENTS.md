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
Markdown layout remain CLI-owned. Semantic spans always index the accompanying
presentation text: map Bash spans into the terminal-formatted argument display
only when that text exactly matches the canonical command, and render fenced
code from the same presented text cached with its spans. Measure only the final
presentation bytes.

Host-owned slash commands must intercept only an exact command submission.
When the composer contains an argument suffix or attachment token, preserve the
input and use the normal prompt submission path rather than discarding it as
part of a lifecycle action.

Markdown fenced code uses `vivi_backend.presentCodeFragment`; the backend owns
language aliases and Tree-sitter tokens while the CLI owns its highlight cache.
