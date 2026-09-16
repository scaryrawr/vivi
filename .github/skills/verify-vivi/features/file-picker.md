# File picker

Vivi opens a workspace file picker when the active composer token starts with
`@`, including eligible hidden files without exposing ignored files or version
control metadata.

## Sub-features

- Typing `@` opens a menu of tracked and unignored workspace files.
- Further typing filters paths without moving or replacing surrounding text.
- Hidden paths such as `.gitignore`, `.github/...`, and unignored dotfiles are
  available.
- Git-ignored paths and metadata under `.git`, `.hg`, `.svn`, `.bzr`,
  `_darcs`, and `CVS` are excluded.
- Paths containing invalid UTF-8 or terminal control bytes are excluded rather
  than passed into the menu or composer.
- Enter replaces the active `@` token with the selected relative path.
- Escape dismisses the picker without changing the draft.
- Enumeration and matching run outside the terminal event loop.
- Reopening immediately reuses a bounded in-memory workspace catalog while a
  fresh Git snapshot is built in the background.

## How to get to it (user POV)

Start `vivi chat`, type `@` in the composer, narrow the path by typing, move
with Up or Down, and press Enter to insert the selected file reference.

## Driving it with verify-vivi

```sh
.github/skills/verify-vivi/bin/verify-vivi chat-file-picker <run-id>
.github/skills/verify-vivi/bin/verify-vivi frame-check <run-id> chat-file-picker
```

The recipe creates an isolated Git workspace containing an unignored hidden
file, an ignored hidden file, and nested `.svn` metadata. It opens the picker,
filters to the eligible hidden file, selects it, and captures the resulting
composer. The normalized PTY transcript must contain `.visible-hidden` and
must not contain `.ignored-hidden` or `.svn/entries`.

## Gotchas

- File enumeration requires `git` and a Git worktree.
- The picker refreshes Git's tracked-plus-unignored view when it opens. A
  previous catalog remains searchable until the refresh completes.
- File references are relative to the active session working directory.
- Catalogs and result pages have explicit memory and path-count limits. The
  catalog byte limit includes both path text and path-span storage, so an
  oversized workspace reports the picker as unavailable instead of consuming
  unbounded memory.
