import { expect, test } from "bun:test";
import { unlink } from "node:fs/promises";
import { scanRepository, scanText } from "./check-boundaries";

test("reports literal violations across production extensions and import forms", async () => {
  const fixtures = [
    ["packages/core/src/forbidden-boundary-fixture.ts", 'import fs from "node:fs";\n'],
    ["packages/core/src/forbidden-boundary-fixture.tsx", 'export { value } from "@opentui/core";\n'],
    ["packages/core/src/forbidden-boundary-fixture.mts", 'const sdk = import("@github/copilot-sdk");\n'],
    ["packages/core/src/forbidden-boundary-fixture.cts", 'const fs = require("fs");\n'],
  ] as const;
  try {
    for (const [path, text] of fixtures) await Bun.write(path, text);
    const messages = (await scanRepository(process.cwd())).map(({ message }) => message);
    expect(messages).toContain(
      'packages/core/src/forbidden-boundary-fixture.ts: core imports forbidden module "node:fs"',
    );
    expect(messages).toContain(
      'packages/core/src/forbidden-boundary-fixture.tsx: core imports forbidden module "@opentui/core"',
    );
    expect(messages).toContain(
      'packages/core/src/forbidden-boundary-fixture.mts: core imports forbidden module "@github/copilot-sdk"',
    );
    expect(messages).toContain(
      'packages/core/src/forbidden-boundary-fixture.cts: core imports forbidden module "fs"',
    );
    expect(messages).toContain(
      'packages/core/src/forbidden-boundary-fixture.mts: SDK import outside packages/copilot-adapter',
    );
    expect(messages).toContain(
      'packages/core/src/forbidden-boundary-fixture.tsx: OpenTUI import outside packages/frontend-opentui',
    );
  } finally {
    for (const [path] of fixtures) await unlink(path);
  }
});

test("normalizes Windows paths before enforcing package ownership", async () => {
  expect(
    scanText(
      "packages\\core\\src\\forbidden.ts",
      'import { CopilotClient } from "@github/copilot-sdk";',
    ).map(({ message }) => message),
  ).toEqual([
    'packages/core/src/forbidden.ts: core imports forbidden module "@github/copilot-sdk"',
    "packages/core/src/forbidden.ts: SDK import outside packages/copilot-adapter",
  ]);
});

test("does not confuse package-name prefixes with Node built-ins", () => {
  expect(scanText("packages/core/src/allowed.ts", 'import parser from "path-to-regexp";')).toEqual([]);
});

test("uses parsed imports instead of matching comments and strings", () => {
  expect(
    scanText(
      "packages/core/src/allowed.ts",
      '// import fs from "fs"\nconst example = \'require("child_process")\';',
    ),
  ).toEqual([]);
  expect(
    scanText(
      "packages/core/src/forbidden.ts",
      'import { spawn } from "child_process";',
    ),
  ).toEqual([
    'packages/core/src/forbidden.ts: core imports forbidden module "child_process"',
  ].map((message) => ({ message })));
});
