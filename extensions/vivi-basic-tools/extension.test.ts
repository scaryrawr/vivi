import { afterAll, expect, mock, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { SessionEventHandler, Tool } from "@github/copilot-sdk";
import type { JoinSessionConfig } from "@github/copilot-sdk/extension";

let tools: Tool[] = [];
let shutdown: SessionEventHandler | undefined;

mock.module("@github/copilot-sdk/extension", () => ({
  joinSession: async (config: JoinSessionConfig) => {
    tools = config.tools ?? [];
    return {
      on: (event: string, handler: SessionEventHandler) => {
        if (event === "session.shutdown") shutdown = handler;
      },
    };
  },
}));

await import("./extension.mjs");

afterAll(async () => {
  shutdown?.({} as never);
});

test("registers the four Vivi tools as built-in replacements", () => {
  expect(tools.map(({ name }) => name)).toEqual(["read", "bash", "edit", "write"]);
  expect(tools.every(({ overridesBuiltInTool }) => overridesBuiltInTool === true)).toBe(true);
});

test("reads selected lines and writes and edits exact content", async () => {
  const root = await mkdtemp(join(tmpdir(), "vivi-basic-tools-"));
  try {
    const path = join(root, "sample.txt");
    await writeFile(path, "\uFEFFone\r\ntwo\r\nthree\r\n");

    expect(await call("read", { path, offset: 2, limit: 2 })).toMatchObject({
      textResultForLlm: "two\r\nthree\r",
      resultType: "success",
    });
    expect(
      await call("edit", {
        path,
        edits: [
          { oldText: "one", newText: "two" },
          { oldText: "two", newText: "three\nfour" },
        ],
      }),
    ).toMatchObject({ resultType: "success" });
    expect(await readFile(path, "utf8")).toBe("\uFEFFtwo\r\nthree\r\nfour\r\nthree\r\n");

    const written = join(root, "nested", "created.txt");
    expect(await call("write", { path: written, content: "hello\n" })).toMatchObject({
      resultType: "success",
    });
    expect(await readFile(written, "utf8")).toBe("hello\n");
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("runs commands and manages persistent Bash processes", async () => {
  expect(await call("bash", { command: "printf out; printf err >&2" })).toMatchObject({
    textResultForLlm: "outerr",
    resultType: "success",
  });
  if (process.platform === "win32") return;

  const started = await call("bash", {
    action: "start",
    command: "read line; printf 'TOOL:%s\\n' \"$line\"",
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
  expect(
    JSON.parse((await call("bash", { action: "stop", shell_id: shellId })).textResultForLlm),
  ).toMatchObject({ was_present: true });
  expect(
    JSON.parse((await call("bash", { action: "stop", shell_id: shellId })).textResultForLlm),
  ).toMatchObject({ was_present: false });
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
