# Design

<!-- impeccable:design-schema 1 -->

## Direction

Vivi's web presentation is a compact native productivity split view. It refuses
the browser-dashboard pattern: there is no marketing header, card grid, metric
strip, or ornamental browser chrome. The project/session rail, active
conversation, and composer are the entire application.

## Use scene

Developers use Vivi for long stretches beside code, terminals, and native
development tools under ordinary office or home lighting. The default surface
is light and quiet; a dark appearance uses the same hierarchy for darker
workspaces.

## Color

The strategy is restrained neutrals plus one selection accent.

- Application ground: cool system gray.
- Sidebar: one step denser than the conversation surface.
- Raised content: white or near-black surfaces with hairline separators.
- Selection and focus: system-like blue.
- Error: semantic red with a lightly tinted field.
- Secondary text: neutral gray that retains readable contrast.

Color communicates emphasis but never carries lifecycle or error meaning by
itself.

## Typography

Use the local operating-system UI stack:

```css
-apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", sans-serif
```

Density is native and compact: 13px application text, 11px metadata, 14px
conversation copy, and restrained 19px empty-state headings. Weight, spacing,
and position establish hierarchy; tracked labels and display typography do not.
Monospace is reserved for tool source and command output.

## Composition

- A fixed narrow sidebar owns project accordion headers and ordered session
  rows.
- A 62px content toolbar names the selected conversation and workspace.
- The transcript uses a readable 72-character measure centered in the detail
  region.
- The composer is anchored near the bottom and remains visually connected to
  the transcript.
- Project headers are full-row controls with exactly one leading disclosure.
- Selected sessions use one solid accent field; no badges or ordinals compete
  with the title.

## Components and states

- Project groups preserve host order through collapse and expansion.
- Session rows display `New conversation` for untitled sessions and keep
  duplicate rows visually equal.
- User messages are compact trailing bubbles; assistant answers remain on the
  reading surface.
- Reasoning and tool activity share a quiet disclosure treatment, while tool
  status stays explicit in text.
- Composer states include enabled, disabled, responding, submission error, and
  host error.
- Focus rings are visible on every interactive element. Reduced motion removes
  pulsing and caret animation.

## Materials and motion

Materials come from subtle value changes, hairline separators, and offset
shadows on the composer and small identity mark. Backdrop blur is used only on
the toolbar to preserve context beneath a native-style material. Motion is
limited to streaming/presence feedback and is disabled for reduced-motion
preferences.

## Responsive rule

The layer is optimized for desktop webviews. At narrower widths the sidebar
contracts and transcript/composer gutters shrink, but the split-view structure
and information hierarchy remain intact. A future host may add native sidebar
visibility controls without changing this visual system.
