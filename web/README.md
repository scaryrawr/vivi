# Vivi web presentation

Vivi's React, TypeScript, and Vite presentation runs against a deterministic
`MockViviHost` for browser development. A separate native entry is packaged
only inside the `SKIP_INSTALL` macOS `ViviWebHostTests.xctest` bundle. It does
not change the shipping macOS window or place WebKit bridge code or web assets
in `Vivi.app`.

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
pnpm build:native
pnpm storybook
pnpm storybook:build
pnpm storybook:smoke
pnpm playwright
pnpm check
```

## Host contract

`src/host/contract.ts` defines the versioned presentation contract. It exposes
one atomic application snapshot and three named commands: select a session,
create a conversation in an existing project, and send a message. Transport is
implemented privately by `src/host/native.ts` for the test-only macOS host.
The bridge uses one named `viviHostV1` handler, validates the closed V1 grammar
at both ends, and preserves snapshot and connection object identity until a
strictly newer complete snapshot arrives.
HostPort V1 has no semantic-span fields; unexpected fields, including attempted
span additions, are rejected instead of being treated as a compatible widening.

Host state is authoritative for project and session order, selection,
lifecycle, transcript content, and errors. React owns only drafts, project and
transcript disclosure, and focus.

The native proof uses a deterministic typed test adapter behind a narrow
domain-facing Swift protocol. It deliberately does not duplicate or adapt
production SDK/session state. A future production cutover can implement that
protocol after the native domain exposes an appropriately narrow command and
snapshot seam.

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
