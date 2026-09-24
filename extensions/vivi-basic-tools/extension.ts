import { randomBytes } from "node:crypto";
import { spawn } from "node:child_process";
import { mkdir, open, readFile, stat, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, resolve } from "node:path";
import { joinSession } from "@github/copilot-sdk/extension";
import type { Tool } from "@github/copilot-sdk";
import { Type } from "@sinclair/typebox";

type BashChild = import("node:child_process").ChildProcessWithoutNullStreams;
type BashExit = { kind: string; value: number | string | null };
interface BashSession {
  shellId: string;
  child: BashChild;
  output: Buffer;
  droppedBytes: number;
  exited: boolean;
  exit: BashExit | null;
  changed: Array<() => void>;
}

const MAX_IMAGE_BYTES = 20 * 1024 * 1024;
const MAX_SESSIONS = 8;
const MAX_OUTPUT_BYTES = 256 * 1024;
const DEFAULT_READ_BYTES = 16 * 1024;
const MAX_READ_BYTES = 32 * 1024;
const MAX_WRITE_BYTES = 16 * 1024;
const DEFAULT_WAIT_MS = 100;
const MAX_WAIT_MS = 5_000;
const SHELL_ID = /^bash_[0-9a-f]{32}$/i;
const sessions = new Map<string, BashSession>();

const ReadParameters = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    offset: Type.Optional(Type.Integer({ minimum: 1 })),
    limit: Type.Optional(Type.Integer({ minimum: 1 })),
  },
  { additionalProperties: false },
);

const BashParameters = Type.Object(
  {
    action: Type.Optional(
      Type.String({ enum: ["run", "start", "list", "read", "write", "stop"], default: "run" }),
    ),
    command: Type.Optional(Type.String({ minLength: 1 })),
    timeout: Type.Optional(Type.Number({ exclusiveMinimum: 0, maximum: 600 })),
    shell_id: Type.Optional(Type.String({ pattern: "^bash_[0-9A-Fa-f]{32}$" })),
    max_bytes: Type.Optional(Type.Integer({ minimum: 1, maximum: MAX_READ_BYTES })),
    wait_ms: Type.Optional(Type.Integer({ minimum: 0, maximum: MAX_WAIT_MS })),
    data: Type.Optional(Type.String()),
    encoding: Type.Optional(Type.String({ enum: ["utf8", "base64"] })),
  },
  { additionalProperties: false },
);

const EditParameters = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    edits: Type.Array(
      Type.Object(
        {
          oldText: Type.String({ minLength: 1 }),
          newText: Type.String(),
        },
        { additionalProperties: false },
      ),
      { minItems: 1 },
    ),
  },
  { additionalProperties: false },
);

const WriteParameters = Type.Object(
  {
    path: Type.String({ minLength: 1 }),
    content: Type.String(),
  },
  { additionalProperties: false },
);

const tools: Tool[] = [
  {
    name: "read",
    description:
      "Read UTF-8 text or a PNG, JPEG, GIF, or WebP image from a file. Images are returned as image content, not text. Paths may be absolute or relative to the workspace. For text only, offset is an optional 1-indexed first line and limit is an optional positive number of lines. Returns the selected text without Vivi-side truncation.",
    parameters: ReadParameters,
    overridesBuiltInTool: true,
    handler: handleRead,
  },
  {
    name: "bash",
    description:
      "Run commands or manage persistent Bash processes. action defaults to run. run requires command and accepts timeout (default 120 seconds, maximum 600). start requires command and returns a shell_id. list takes no other fields. read requires shell_id and accepts max_bytes (default 16384, maximum 32768) and wait_ms (default 100, maximum 5000). write requires shell_id and data, with encoding utf8 (default) or base64; decoded input may not exceed 16384 bytes. stop requires shell_id and is idempotent.",
    parameters: BashParameters,
    overridesBuiltInTool: true,
    handler: handleBash,
  },
  {
    name: "edit",
    description:
      "Edit one text file using exact replacements. Every oldText must be non-empty, occur exactly once in the original file, and not overlap another edit. All matches are planned before one write.",
    parameters: EditParameters,
    overridesBuiltInTool: true,
    handler: handleEdit,
  },
  {
    name: "write",
    description:
      "Create or overwrite a file with exact content. Paths may be absolute or relative to the workspace. Missing parent directories are created.",
    parameters: WriteParameters,
    overridesBuiltInTool: true,
    handler: handleWrite,
  },
];

const session = await joinSession({
  excludedTools: ["builtin:read", "builtin:bash", "builtin:edit", "builtin:write"],
  tools,
});

session.on("session.shutdown", stopAllSessions);

async function handleRead(arguments_: unknown) {
  try {
    assertArguments(arguments_);
    const path = resolvePath(requireString(arguments_, "path"));
    const offset = optionalPositiveInteger(arguments_, "offset") ?? 1;
    const limit = optionalPositiveInteger(arguments_, "limit") ?? Number.MAX_SAFE_INTEGER;
    const format = await detectImageFile(path);
    if (format !== undefined) {
      if (arguments_.offset !== undefined || arguments_.limit !== undefined) {
        return failure("offset and limit select text lines and cannot be used with images.");
      }
      const metadata = await stat(path);
      if (metadata.size > MAX_IMAGE_BYTES) return failure("read failed: ImageTooLarge.");
      const bytes = await readFile(path);
      return {
        textResultForLlm: `Image: ${arguments_.path} (${format}, ${bytes.length} bytes)`,
        binaryResultsForLlm: [
          {
            type: "image",
            data: bytes.toString("base64"),
            mimeType: format,
            description: `Image: ${arguments_.path}`,
          },
        ],
        resultType: "success",
      };
    }

    const bytes = await readFile(path);
    if (bytes.includes(0)) return failure("read failed: UnsupportedBinaryFile.");
    const content = decodeUtf8(bytes, "read failed: InvalidUtf8.");
    const lines = content.split("\n");
    if (offset > lines.length) {
      return failure(`Offset ${offset} is beyond end of file (${lines.length} lines total).`);
    }
    return success(lines.slice(offset - 1, offset - 1 + limit).join("\n"));
  } catch (error) {
    return failure(`read failed: ${errorMessage(error)}.`);
  }
}

async function handleBash(arguments_: unknown) {
  try {
    assertArguments(arguments_);
    const action = optionalString(arguments_, "action") ?? "run";
    switch (action) {
      case "run":
        requireOnly(arguments_, ["action", "command", "timeout"]);
        return await runBash(
          requireString(arguments_, "command"),
          optionalNumber(arguments_, "timeout") ?? 120,
        );
      case "start":
        requireOnly(arguments_, ["action", "command"]);
        return await startBash(requireString(arguments_, "command"));
      case "list":
        requireOnly(arguments_, ["action"]);
        return success(
          JSON.stringify({
            sessions: [...sessions.values()].map(snapshot),
          }),
        );
      case "read":
        requireOnly(arguments_, ["action", "shell_id", "max_bytes", "wait_ms"]);
        return await readBash(
          requireShell(arguments_),
          optionalPositiveInteger(arguments_, "max_bytes") ?? DEFAULT_READ_BYTES,
          optionalNonNegativeInteger(arguments_, "wait_ms") ?? DEFAULT_WAIT_MS,
        );
      case "write":
        requireOnly(arguments_, ["action", "shell_id", "data", "encoding"]);
        return writeBash(
          requireShell(arguments_),
          requireString(arguments_, "data", true),
          optionalString(arguments_, "encoding") ?? "utf8",
        );
      case "stop":
        requireOnly(arguments_, ["action", "shell_id"]);
        return await stopBash(requireString(arguments_, "shell_id"));
      default:
        return failure(`bash failed: UnknownAction.`);
    }
  } catch (error) {
    return failure(`bash failed: ${errorMessage(error)}.`);
  }
}

async function handleEdit(arguments_: unknown) {
  try {
    assertArguments(arguments_);
    const path = resolvePath(requireString(arguments_, "path"));
    const edits = arguments_.edits;
    if (!Array.isArray(edits) || edits.length === 0) throw new Error("EmptyEdits");
    const raw = await readFile(path);
    const hasBom = raw.length >= 3 && raw[0] === 0xef && raw[1] === 0xbb && raw[2] === 0xbf;
    const content = decodeUtf8(hasBom ? raw.subarray(3) : raw, "InvalidUtf8");
    const lineEnding = content.includes("\r\n") ? "\r\n" : "\n";
    const normalized = normalizeLines(content);
    const replacements = edits.map((edit) => {
      if (typeof edit !== "object" || edit === null) throw new Error("InvalidEdit");
      const oldText = normalizeLines(requireString(edit, "oldText"));
      const newText = normalizeLines(requireString(edit, "newText", true));
      const start = normalized.indexOf(oldText);
      if (start < 0) throw new Error("OldTextNotFound");
      if (normalized.indexOf(oldText, start + oldText.length) >= 0) {
        throw new Error("OldTextNotUnique");
      }
      return { start, end: start + oldText.length, newText };
    });
    replacements.sort((left, right) => left.start - right.start);
    for (let index = 1; index < replacements.length; index += 1) {
      const current = replacements[index];
      const previous = replacements[index - 1];
      if (current === undefined || previous === undefined) throw new Error("InvalidEdit");
      if (current.start < previous.end) {
        throw new Error("OverlappingEdits");
      }
    }

    let changed = "";
    let cursor = 0;
    for (const replacement of replacements) {
      changed += normalized.slice(cursor, replacement.start);
      changed += replacement.newText;
      cursor = replacement.end;
    }
    changed += normalized.slice(cursor);
    if (changed === normalized) throw new Error("NoChanges");
    const restored = lineEnding === "\r\n" ? changed.replaceAll("\n", "\r\n") : changed;
    await writeFile(path, `${hasBom ? "\uFEFF" : ""}${restored}`, "utf8");
    return success(`Successfully replaced ${edits.length} block(s) in ${arguments_.path}.`);
  } catch (error) {
    return failure(`edit failed: ${errorMessage(error)}.`);
  }
}

async function handleWrite(arguments_: unknown) {
  try {
    assertArguments(arguments_);
    const path = resolvePath(requireString(arguments_, "path"));
    const content = requireString(arguments_, "content", true);
    await mkdir(dirname(path), { recursive: true });
    await writeFile(path, content, "utf8");
    return success(`Successfully wrote to ${arguments_.path}.`);
  } catch (error) {
    return failure(`write failed: ${errorMessage(error)}.`);
  }
}

async function runBash(command: string, timeoutSeconds: number) {
  if (!Number.isFinite(timeoutSeconds) || timeoutSeconds <= 0 || timeoutSeconds > 600) {
    throw new Error("InvalidTimeout");
  }
  const child = spawnBash(command);
  const output: Buffer[] = [];
  child.stdout.on("data", (data) => output.push(Buffer.from(data)));
  child.stderr.on("data", (data) => output.push(Buffer.from(data)));
  const timedOut = await waitForExit(child, timeoutSeconds * 1000);
  if (timedOut) {
    await terminateChild(child);
    return failure(`Command timed out after ${timeoutSeconds} seconds.`);
  }
  const text = Buffer.concat(output).toString("utf8") || "(no output)";
  if (child.exitCode === 0) return success(text);
  if (child.signalCode !== null) {
    return failure(`${text}\n\nCommand terminated by signal ${child.signalCode}.`);
  }
  return failure(`${text}\n\nCommand exited with code ${child.exitCode}.`);
}

async function startBash(command: string) {
  if (sessions.size >= MAX_SESSIONS) throw new Error("TooManyBashSessions");
  const shellId = `bash_${randomBytes(16).toString("hex")}`;
  const child = spawnBash(command);
  const state: BashSession = {
    shellId,
    child,
    output: Buffer.alloc(0),
    droppedBytes: 0,
    exited: false,
    exit: null,
    changed: [],
  };
  sessions.set(shellId, state);
  child.stdout.on("data", (data) => appendOutput(state, data));
  child.stderr.on("data", (data) => appendOutput(state, data));
  child.on("exit", (code, signal) => {
    state.exited = true;
    state.exit =
      code !== null
        ? { kind: "code", value: code }
        : signal !== null
          ? { kind: "signal", value: signal }
          : { kind: "unknown", value: null };
    notifyChanged(state);
  });
  await waitForOutput(state, DEFAULT_WAIT_MS);
  return success(JSON.stringify(takeOutput(state, DEFAULT_READ_BYTES)));
}

async function readBash(state: BashSession, maxBytes: number, waitMs: number) {
  if (maxBytes > MAX_READ_BYTES) throw new Error("InvalidReadLimit");
  if (waitMs > MAX_WAIT_MS) throw new Error("InvalidWait");
  await waitForOutput(state, waitMs);
  return success(JSON.stringify(takeOutput(state, maxBytes)));
}

function writeBash(state: BashSession, data: string, encoding: string) {
  if (state.exited) throw new Error("ShellNotRunning");
  const bytes = decodeInput(data, encoding);
  if (bytes.length > MAX_WRITE_BYTES) throw new Error("InputTooLarge");
  state.child.stdin.write(bytes);
  return success(
    JSON.stringify({
      shell_id: state.shellId,
      state: state.exited ? "exited" : "running",
      exit: state.exit,
      accepted_bytes: bytes.length,
    }),
  );
}

async function stopBash(shellId: string) {
  if (!SHELL_ID.test(shellId)) throw new Error("InvalidShellId");
  const state = sessions.get(shellId);
  if (state === undefined) {
    return success(JSON.stringify({ shell_id: shellId, was_present: false }));
  }
  sessions.delete(shellId);
  await terminateChild(state.child);
  return success(JSON.stringify({ shell_id: shellId, was_present: true }));
}

function stopAllSessions() {
  for (const state of sessions.values()) {
    void terminateChild(state.child);
  }
  sessions.clear();
}

function spawnBash(command: string): BashChild {
  if (command.length === 0 || command.includes("\0")) throw new Error("InvalidCommand");
  return spawn("bash", ["-c", `exec 2>&1\n${command}`], {
    cwd: process.cwd(),
    detached: process.platform !== "win32",
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function appendOutput(state: BashSession, chunk: Buffer | Uint8Array) {
  const combined = Buffer.concat([state.output, Buffer.from(chunk)]);
  if (combined.length <= MAX_OUTPUT_BYTES) {
    state.output = combined;
  } else {
    const dropped = combined.length - MAX_OUTPUT_BYTES;
    state.output = combined.subarray(dropped);
    state.droppedBytes += dropped;
  }
  notifyChanged(state);
}

function snapshot(state: BashSession) {
  return {
    shell_id: state.shellId,
    state: state.exited ? "exited" : "running",
    exit: state.exit,
    unread_bytes: state.output.length,
    dropped_bytes: state.droppedBytes,
  };
}

function takeOutput(state: BashSession, maxBytes: number) {
  const bytes = state.output.subarray(0, maxBytes);
  state.output = state.output.subarray(bytes.length);
  const decoded = tryDecodeUtf8(bytes);
  return {
    shell_id: state.shellId,
    state: state.exited ? "exited" : "running",
    exit: state.exit,
    output: decoded ?? bytes.toString("base64"),
    encoding: decoded === undefined ? "base64" : "utf8",
    more: state.output.length > 0,
    dropped_bytes: state.droppedBytes,
  };
}

async function waitForOutput(state: BashSession, waitMs: number) {
  if (state.output.length > 0 || state.exited || waitMs === 0) return;
  await new Promise((resolve_) => {
    let settled = false;
    const finish = () => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      const index = state.changed.indexOf(finish);
      if (index >= 0) state.changed.splice(index, 1);
      resolve_(undefined);
    };
    const timeout = setTimeout(finish, waitMs);
    state.changed.push(finish);
  });
}

function notifyChanged(state: BashSession) {
  for (const resolve_ of state.changed.splice(0)) resolve_();
}

async function waitForExit(child: BashChild, timeoutMs: number) {
  if (child.exitCode !== null || child.signalCode !== null) return false;
  return await new Promise((resolve_) => {
    const timeout = setTimeout(() => resolve_(true), timeoutMs);
    child.once("exit", () => {
      clearTimeout(timeout);
      resolve_(false);
    });
  });
}

async function terminateChild(child: BashChild) {
  if (child.exitCode !== null || child.signalCode !== null) return;
  const pid = child.pid;
  if (pid === undefined) {
    child.kill();
    return;
  }
  try {
    if (process.platform === "win32") {
      const killer = spawn("taskkill", ["/pid", String(pid), "/t", "/f"], {
        stdio: "ignore",
      });
      await new Promise((resolve_) => killer.once("exit", resolve_));
    } else {
      process.kill(-pid, "SIGTERM");
      if (await waitForExit(child, 1_000)) process.kill(-pid, "SIGKILL");
    }
  } catch {
    child.kill();
  }
}

async function detectImageFile(path: string): Promise<string | undefined> {
  const handle = await open(path, "r");
  try {
    const prefix = Buffer.alloc(12);
    const { bytesRead } = await handle.read(prefix, 0, prefix.length, 0);
    return detectImage(prefix.subarray(0, bytesRead));
  } finally {
    await handle.close();
  }
}

function detectImage(bytes: Buffer): string | undefined {
  if (bytes.subarray(0, 8).equals(Buffer.from("\x89PNG\r\n\x1a\n", "binary"))) {
    return "image/png";
  }
  if (bytes.subarray(0, 3).equals(Buffer.from([0xff, 0xd8, 0xff]))) return "image/jpeg";
  const signature = bytes.subarray(0, 6).toString("ascii");
  if (signature === "GIF87a" || signature === "GIF89a") return "image/gif";
  if (
    bytes.length >= 12 &&
    bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
    bytes.subarray(8, 12).toString("ascii") === "WEBP"
  ) {
    return "image/webp";
  }
  return undefined;
}

function resolvePath(path: string): string {
  if (path.includes("\0")) throw new Error("InvalidPath");
  return isAbsolute(path) ? resolve(path) : resolve(process.cwd(), path);
}

function normalizeLines(value: string): string {
  return value.replaceAll("\r\n", "\n").replaceAll("\r", "\n");
}

function decodeUtf8(bytes: Buffer, message: string): string {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    throw new Error(message);
  }
}

function tryDecodeUtf8(bytes: Buffer): string | undefined {
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return undefined;
  }
}

function decodeInput(data: string, encoding: string): Buffer {
  if (encoding === "utf8") return Buffer.from(data, "utf8");
  if (
    encoding !== "base64" ||
    !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(data)
  ) {
    throw new Error("InvalidEncoding");
  }
  return Buffer.from(data, "base64");
}

function requireShell(arguments_: Record<string, unknown>): BashSession {
  const shellId = requireString(arguments_, "shell_id");
  if (!SHELL_ID.test(shellId)) throw new Error("InvalidShellId");
  const state = sessions.get(shellId);
  if (state === undefined) throw new Error("UnknownShell");
  return state;
}

function assertArguments(value: unknown): asserts value is Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("InvalidArguments");
  }
}

function requireOnly(arguments_: Record<string, unknown>, allowed: string[]) {
  for (const key of Object.keys(arguments_)) {
    if (!allowed.includes(key)) throw new Error("UnexpectedBashArgument");
  }
}

function requireString(value: Record<string, unknown>, key: string, allowEmpty = false): string {
  const field = value?.[key];
  if (typeof field !== "string" || (!allowEmpty && field.length === 0)) {
    throw new Error(`Invalid${capitalize(key)}`);
  }
  return field;
}

function optionalString(value: Record<string, unknown>, key: string): string | undefined {
  const field = value?.[key];
  if (field === undefined) return undefined;
  if (typeof field !== "string") throw new Error(`Invalid${capitalize(key)}`);
  return field;
}

function optionalNumber(value: Record<string, unknown>, key: string): number | undefined {
  const field = value?.[key];
  if (field === undefined) return undefined;
  if (typeof field !== "number") throw new Error(`Invalid${capitalize(key)}`);
  return field;
}

function optionalPositiveInteger(value: Record<string, unknown>, key: string): number | undefined {
  const field = value?.[key];
  if (field === undefined) return undefined;
  if (typeof field !== "number" || !Number.isSafeInteger(field) || field <= 0) {
    throw new Error(`Invalid${capitalize(key)}`);
  }
  return field;
}

function optionalNonNegativeInteger(
  value: Record<string, unknown>,
  key: string,
): number | undefined {
  const field = value?.[key];
  if (field === undefined) return undefined;
  if (typeof field !== "number" || !Number.isSafeInteger(field) || field < 0) {
    throw new Error(`Invalid${capitalize(key)}`);
  }
  return field;
}

function capitalize(value: string): string {
  return value.length === 0 ? value : `${value.charAt(0).toUpperCase()}${value.slice(1)}`;
}

function success(text: string) {
  return { textResultForLlm: text, resultType: "success" };
}

function failure(text: string) {
  return { textResultForLlm: text, resultType: "failure", error: text };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
