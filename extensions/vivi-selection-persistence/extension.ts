import { randomBytes, randomUUID } from "node:crypto";
import { chmod, mkdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
import { joinSession } from "@github/copilot-sdk/extension";

const settingsPath = process.env.VIVI_SETTINGS_PATH;
const session = await joinSession();
let writeQueue = Promise.resolve();

if (settingsPath !== undefined && settingsPath.length > 0) {
  try {
    await persistCurrentSelection();
  } catch (error) {
    await logPersistenceFailure(error);
  }
  session.on("session.model_change", () => {
    writeQueue = writeQueue.then(persistCurrentSelection).catch(logPersistenceFailure);
  });
}

async function persistCurrentSelection() {
  const current = await session.rpc.model.getCurrent();
  if (settingsPath === undefined || current.modelId === undefined) return;
  const reasoning =
    current.reasoningEffort === undefined ? null : normalizeReasoning(current.reasoningEffort);
  const content = `${JSON.stringify(
    {
      version: 3,
      default_selection: {
        model_id: current.modelId,
        reasoning,
      },
      write_id: randomBytes(16).toString("hex"),
    },
    null,
    2,
  )}\n`;

  await mkdir(dirname(settingsPath), { recursive: true, mode: 0o700 });
  const temporary = `${settingsPath}.${process.pid}.${randomUUID()}.tmp`;
  await writeFile(temporary, content, { encoding: "utf8", mode: 0o600 });
  await chmod(temporary, 0o600).catch(ignoreWindowsPermissionError);
  try {
    await rename(temporary, settingsPath);
  } catch (error) {
    if (process.platform !== "win32") throw error;
    await rm(settingsPath, { force: true });
    await rename(temporary, settingsPath);
  }
  await chmod(settingsPath, 0o600).catch(ignoreWindowsPermissionError);
}

function normalizeReasoning(reasoning: string): string | null {
  const normalized = reasoning === "off" ? "none" : reasoning;
  return ["none", "minimal", "low", "medium", "high", "xhigh", "max"].includes(normalized)
    ? normalized
    : null;
}

async function logPersistenceFailure(error: unknown): Promise<void> {
  await session.log(`Vivi could not persist the model selection: ${String(error)}`, {
    level: "warning",
    ephemeral: true,
  });
}

function ignoreWindowsPermissionError(error: unknown): void {
  if (process.platform !== "win32") throw error;
}
