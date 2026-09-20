import { expect, test } from "bun:test";
import {
  extractCommandNames,
  normalizeLineEndings,
  runCompiledHelpParity,
  type ArtifactIdentity,
  type CompiledArtifactSpec,
  type CompiledHelpFixture,
} from "./compiled-parity.js";

const fixture: CompiledHelpFixture = {
  name: "help",
  argv: ["--help"],
  expected: {
    commandNames: ["models", "chat"],
    stdout: "Usage\n\nCommands:\n  models     List models.\n  chat       Start chat.\n\n",
    stderr: "",
    exitStatus: 0,
  },
};

const artifacts: readonly [CompiledArtifactSpec, CompiledArtifactSpec] = [
  { label: "zig", requestedPath: "/zig/vivi", buildCommand: ["zig", "build"] },
  { label: "bun", requestedPath: "/bun/vivi", buildCommand: ["bun", "run", "build:vivi"] },
];

function identity(label: "zig" | "bun"): ArtifactIdentity {
  return {
    label,
    buildCommand: label === "zig" ? ["zig", "build"] : ["bun", "run", "build:vivi"],
    requestedPath: `/${label}/vivi`,
    resolvedPath: `/${label}/vivi`,
    byteLength: 10,
    sha256: `${label}-hash`,
    fileId: `${label}-file`,
    executable: true,
  };
}

function dependencies(overrides: Partial<Parameters<typeof runCompiledHelpParity>[2]> = {}) {
  return {
    build: async () => ({ ok: true }),
    identify: async (artifact: CompiledArtifactSpec) => identity(artifact.label),
    execute: async (artifact: ArtifactIdentity) => ({
      exitStatus: 0,
      stdout: fixture.expected.stdout,
      stderr: "",
    }),
    ...overrides,
  };
}

test("returns PASS for exact compiled observations", async () => {
  const result = await runCompiledHelpParity(fixture, artifacts, dependencies());
  expect(result.status).toBe("PASS");
});

test("returns FAIL with the first literal mismatch", async () => {
  const result = await runCompiledHelpParity(
    fixture,
    artifacts,
    dependencies({
      execute: async (artifact) => ({
        exitStatus: artifact.label === "zig" ? 0 : 1,
        stdout: fixture.expected.stdout,
        stderr: "",
      }),
    }),
  );
  expect(result.status).toBe("FAIL");
  expect(result.firstMismatch).toEqual({
    path: "$.exitStatus",
    expected: 0,
    actual: 1,
    expectedLiteral: "0",
    actualLiteral: "1",
  });
});

test("reports the first mismatched help line with literal values", async () => {
  const result = await runCompiledHelpParity(
    fixture,
    artifacts,
    dependencies({
      execute: async (artifact) => ({
        exitStatus: 0,
        stdout:
          artifact.label === "bun"
            ? fixture.expected.stdout.replace("List models.", "List other models.")
            : fixture.expected.stdout,
        stderr: "",
      }),
    }),
  );
  expect(result.firstMismatch).toEqual({
    path: "$.stdout.lines[3]",
    expected: "  models     List models.",
    actual: "  models     List other models.",
    expectedLiteral: '"  models     List models."',
    actualLiteral: '"  models     List other models."',
  });
});

test("returns INCONCLUSIVE when a build is unavailable", async () => {
  const result = await runCompiledHelpParity(
    fixture,
    artifacts,
    dependencies({ build: async () => ({ ok: false, details: "missing zig" }) }),
  );
  expect(result).toEqual({
    status: "INCONCLUSIVE",
    fixture: "help",
    reason: "missing zig",
  });
});

test("returns INCONCLUSIVE when artifact identity collides", async () => {
  const result = await runCompiledHelpParity(
    fixture,
    artifacts,
    dependencies({
      identify: async () => identity("zig"),
    }),
  );
  expect(result.status).toBe("INCONCLUSIVE");
});

test("returns INCONCLUSIVE when an artifact changes before spawn", async () => {
  let identifyCount = 0;
  const result = await runCompiledHelpParity(
    fixture,
    artifacts,
    dependencies({
      identify: async (artifact) => {
        identifyCount++;
        const result = identity(artifact.label);
        return identifyCount === 3 && artifact.label === "zig"
          ? { ...result, sha256: "changed-hash" }
          : result;
      },
    }),
  );
  expect(result).toEqual({
    status: "INCONCLUSIVE",
    fixture: "help",
    reason: "zig artifact identity changed before spawn",
  });
});

test("returns INCONCLUSIVE when a process does not exit", async () => {
  const result = await runCompiledHelpParity(
    fixture,
    artifacts,
    dependencies({
      execute: async () => ({
        exitStatus: null,
        stdout: "",
        stderr: "",
      }),
    }),
  );
  expect(result).toEqual({
    status: "INCONCLUSIVE",
    fixture: "help",
    reason: "zig process did not exit",
  });
});

test("matches command names exactly and in order", () => {
  expect(extractCommandNames(fixture.expected.stdout)).toEqual(["models", "chat"]);
  expect(extractCommandNames(fixture.expected.stdout.replace("chat       ", "chatty     "))).toEqual([
    "models",
    "chatty",
  ]);
});

test("normalizes only platform line endings", () => {
  expect(normalizeLineEndings("a\r\nb\rc\n")).toBe("a\nb\nc\n");
  expect(normalizeLineEndings("a \n")).toBe("a \n");
});
