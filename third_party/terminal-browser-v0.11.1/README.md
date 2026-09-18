# terminal-browser v0.11.1 contract provenance

Vivi's terminal-browser contract fixtures are derived from
`zenbu-labs/terminal-browser` v0.11.1:

- annotated tag object: `c53deaa437b704110ab3dc66e8d52bde04de5c1f`;
- peeled commit: `6d682348f4af469b56fa0fd8331b4eb967030893`;
- source: <https://github.com/zenbu-labs/terminal-browser/tree/6d682348f4af469b56fa0fd8331b4eb967030893>.
- Darwin arm64 release asset SHA-256:
  `9b21729e47bcc07e969913223705ce1ae5bcaa8e49094d6c9705c4cca8311d90`.

The fixtures reproduce the documented command names, field names, and minimal
representative JSON shapes from `cli/src/main.ts`, `cli/src/ls.ts`,
`cli/src/action.ts`, `browser/src/registry.ts`, and
`browser/src/session/tabs.ts`. The fake executable is original Vivi test code;
the upstream executable and source are not vendored.

The retained `LICENSE` is the upstream MIT license at the pinned commit.
