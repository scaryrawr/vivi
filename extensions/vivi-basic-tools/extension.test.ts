import { afterAll, expect, mock, test } from "bun:test";
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SessionEventHandler, Tool } from "@github/copilot-sdk";
import type { JoinSessionConfig } from "@github/copilot-sdk/extension";

let tools: Tool[] = [];
let excludedTools: JoinSessionConfig["excludedTools"];
let shutdown: SessionEventHandler | undefined;
let workingDirectory = process.cwd();

mock.module("@github/copilot-sdk/extension", () => ({
  joinSession: async (config: JoinSessionConfig) => {
    tools = config.tools ?? [];
    excludedTools = config.excludedTools;
    return {
      rpc: { metadata: { snapshot: async () => ({ workingDirectory }) } },
      on: (event: string, handler: SessionEventHandler) => {
        if (event === "session.shutdown") shutdown = handler;
      },
    };
  },
}));

// @ts-expect-error Generated ESM is built before tests and has no declaration file.
await import("../../dist/extensions/vivi-basic-tools/extension.mjs");

afterAll(async () => {
  shutdown?.({} as never);
});

test("registers the four Vivi tools as built-in replacements", () => {
  expect(tools.map(({ name }) => name)).toEqual(["read", "bash", "edit", "write"]);
  expect(tools.every(({ overridesBuiltInTool }) => overridesBuiltInTool === true)).toBe(true);
  expect(tools.find(({ name }) => name === "read")?.skipPermission).toBe(true);
  expect(
    tools.filter(({ name }) => name !== "read").every(({ skipPermission }) => !skipPermission),
  ).toBe(true);
  expect(excludedTools).toEqual(["builtin:bash", "builtin:edit"]);
});

test("publishes the existing JSON Schema contracts", () => {
  expect(schema("read")).toEqual({
    type: "object",
    additionalProperties: false,
    properties: {
      path: { type: "string", minLength: 1 },
      offset: { type: "integer", minimum: 1 },
      limit: { type: "integer", minimum: 1 },
    },
    required: ["path"],
  });
  expect(schema("bash")).toEqual({
    type: "object",
    additionalProperties: false,
    properties: {
      action: {
        type: "string",
        enum: ["run", "start", "list", "read", "write", "stop"],
        default: "run",
      },
      command: { type: "string", minLength: 1 },
      timeout: { type: "number", exclusiveMinimum: 0, maximum: 600 },
      shell_id: { type: "string", pattern: "^bash_[0-9A-Fa-f]{32}$" },
      max_bytes: { type: "integer", minimum: 1, maximum: 32768 },
      wait_ms: { type: "integer", minimum: 0, maximum: 5000 },
      data: { type: "string" },
      encoding: { type: "string", enum: ["utf8", "base64"] },
    },
  });
  expect(schema("edit")).toEqual({
    type: "object",
    additionalProperties: false,
    properties: {
      path: { type: "string", minLength: 1 },
      edits: {
        type: "array",
        minItems: 1,
        items: {
          type: "object",
          additionalProperties: false,
          properties: {
            oldText: { type: "string", minLength: 1 },
            newText: { type: "string" },
          },
          required: ["oldText", "newText"],
        },
      },
    },
    required: ["path", "edits"],
  });
  expect(schema("write")).toEqual({
    type: "object",
    additionalProperties: false,
    properties: {
      path: { type: "string", minLength: 1 },
      content: { type: "string" },
    },
    required: ["path", "content"],
  });
});

test("reads selected lines and writes and edits exact content", async () => {
  const root = await mkdtemp(join(tmpdir(), "vivi-basic-tools-"));
  try {
    workingDirectory = root;
    const path = join(root, "sample.txt");
    await writeFile(path, "\uFEFFone\r\ntwo\r\nthree\r\n");

    expect(await call("read", { path: "sample.txt", offset: 2, limit: 2 })).toMatchObject({
      textResultForLlm: "two\r\nthree\r",
      resultType: "success",
    });
    expect(
      await call("edit", {
        path: "sample.txt",
        edits: [
          { oldText: "one", newText: "two" },
          { oldText: "two", newText: "three\nfour" },
        ],
      }),
    ).toMatchObject({ resultType: "success" });
    expect(await readFile(path, "utf8")).toBe("\uFEFFtwo\r\nthree\r\nfour\r\nthree\r\n");

    const written = join(root, "nested", "created.txt");
    expect(await call("write", { path: "nested/created.txt", content: "hello\n" })).toMatchObject({
      resultType: "success",
    });
    expect(await readFile(written, "utf8")).toBe("hello\n");

    workingDirectory = join(root, "nested");
    expect(await call("read", { path: "created.txt" })).toMatchObject({
      textResultForLlm: "hello\n",
      resultType: "success",
    });
  } finally {
    workingDirectory = process.cwd();
    await rm(root, { recursive: true, force: true });
  }
});

test("runs commands and manages persistent Bash processes", async () => {
  const root = await mkdtemp(join(tmpdir(), "vivi-bash-tools-"));
  try {
    workingDirectory = root;
    if (process.platform !== "win32") {
      expect(await call("bash", { command: "pwd" })).toMatchObject({
        textResultForLlm: `${await realpath(root)}\n`,
        resultType: "success",
      });
      workingDirectory = join(root, "nested");
      await mkdir(workingDirectory);
      expect(await call("bash", { command: "pwd" })).toMatchObject({
        textResultForLlm: `${await realpath(workingDirectory)}\n`,
        resultType: "success",
      });
    }
    expect(await call("bash", { command: "printf out; printf err >&2" })).toMatchObject({
      textResultForLlm: "outerr",
      resultType: "success",
    });
    if (process.platform === "win32") return;

    const started = await call("bash", {
      action: "start",
      command: "read line; pwd; printf 'TOOL:%s\\n' \"$line\"",
    });
    const shellId = JSON.parse(started.textResultForLlm).shell_id;
    expect(shellId).toMatch(/^bash_[0-9a-f]{32}$/);
    await call("bash", { action: "write", shell_id: shellId, data: "ready\n" });

    let output = "";
    for (let attempt = 0; attempt < 10 && !output.includes("TOOL:ready"); attempt += 1) {
      const read = await call("bash", {
        action: "read",
        shell_id: shellId,
        wait_ms: 500,
      });
      output += JSON.parse(read.textResultForLlm).output;
    }
    expect(output).toContain("TOOL:ready");
    expect(output).toContain(await realpath(workingDirectory));
    expect(
      JSON.parse((await call("bash", { action: "stop", shell_id: shellId })).textResultForLlm),
    ).toMatchObject({ was_present: true });
    expect(
      JSON.parse((await call("bash", { action: "stop", shell_id: shellId })).textResultForLlm),
    ).toMatchObject({ was_present: false });
  } finally {
    workingDirectory = process.cwd();
    await rm(root, { recursive: true, force: true });
  }
});

async function call(name: string, arguments_: unknown) {
  const tool = tools.find((candidate) => candidate.name === name);
  if (tool?.handler === undefined) throw new Error(`Missing ${name} handler`);
  return (await tool.handler(arguments_, {
    sessionId: "session",
    toolCallId: "call",
    toolName: name,
    arguments: arguments_,
  })) as {
    textResultForLlm: string;
    resultType: string;
  };
}

function schema(name: string): unknown {
  const parameters = tools.find((tool) => tool.name === name)?.parameters;
  if (parameters === undefined) throw new Error(`Missing ${name} schema`);
  return JSON.parse(JSON.stringify(parameters));
}
