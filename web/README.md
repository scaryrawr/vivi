# Vivi web presentation

Layer 1 of Vivi's presentation migration is a standalone React, TypeScript, and
Vite workspace. It runs against a deterministic `MockViviHost`; it does not
embed a `WKWebView`, add a script message handler, or change the shipping macOS
window.

## Prerequisites

- Node.js 24
- pnpm 12 available directly in `PATH`
- Chromium installed for Playwright (`pnpm exec playwright install chromium`)

Corepack is not required and should not be activated for this workspace.
The committed `.npmrc` uses the Microsoft npm package-feed proxy required by
the development and CI environments.

## Commands

```sh
pnpm install --frozen-lockfile
pnpm dev
pnpm typecheck
pnpm lint
pnpm format
pnpm test
pnpm build
pnpm storybook
pnpm storybook:build
pnpm playwright
pnpm check
```

## Host contract

`src/host/contract.ts` defines the versioned presentation contract. It exposes
one atomic application snapshot and three named commands: select a session,
create a conversation in an existing project, and send a message. Transport is
deliberately absent. The browser mock implements the same port as a future
native adapter.

Host state is authoritative for project and session order, selection,
lifecycle, transcript content, and errors. React owns only drafts, project and
transcript disclosure, and focus.

Layer 2 must implement `ViviHostPort` in Swift, adapt the existing Zig/C ABI
events into complete `HostSnapshot` values, validate protocol version 1,
deduplicate `ClientSubmissionId`, preserve stable session and transcript IDs,
publish monotonically newer snapshots, and bridge the three named commands.
The transport framing and `WKScriptMessageHandler` payloads remain private to
that adapter.

## Content security policy

The production build is designed for:

```text
default-src 'none';
script-src 'self';
style-src 'self';
img-src 'self' data:;
font-src 'self';
connect-src 'none';
base-uri 'none';
form-action 'none'
```

The bundle uses system fonts and local build assets only. It does not require
remote network access or `eval`.

This template provides a minimal setup to get React working in Vite with HMR and some Oxlint rules.

Currently, two official plugins are available:

- [@vitejs/plugin-react](https://github.com/vitejs/vite-plugin-react/blob/main/packages/plugin-react) uses [Oxc](https://oxc.rs)
- [@vitejs/plugin-react-swc](https://github.com/vitejs/vite-plugin-react/blob/main/packages/plugin-react-swc) uses [SWC](https://swc.rs/)

## React Compiler

The React Compiler is not enabled on this template because of its impact on development and build performance. To add it, see [this documentation](https://react.dev/learn/react-compiler/installation).

## Expanding the Oxlint configuration

If you are developing a production application, we recommend enabling type-aware lint rules by installing `oxlint-tsgolint` and editing `.oxlintrc.json`:

```json
{
  "$schema": "./node_modules/oxlint/configuration_schema.json",
  "plugins": ["react", "typescript", "oxc"],
  "options": {
    "typeAware": true
  },
  "rules": {
    "react/rules-of-hooks": "error",
    "react/only-export-components": ["warn", { "allowConstantExport": true }]
  }
}
```

See the [Oxlint rules documentation](https://oxc.rs/docs/guide/usage/linter/rules) for the full list of rules and categories.
