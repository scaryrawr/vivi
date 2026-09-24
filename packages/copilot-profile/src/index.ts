import { chmod, mkdir, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { LocalProviderConfiguration } from "@vivi/provider-discovery";
// @ts-expect-error Bun's text loader embeds the generated ESM as a string.
import basicToolsExtension from "../../../dist/extensions/vivi-basic-tools/extension.mjs" with { type: "text" };
// @ts-expect-error Bun's text loader embeds the generated ESM as a string.
import localModelPolicyExtension from "../../../dist/extensions/vivi-local-model-policy/extension.mjs" with { type: "text" };
// @ts-expect-error Bun's text loader embeds the generated ESM as a string.
import reasoningExtension from "../../../dist/extensions/vivi-reasoning/extension.mjs" with { type: "text" };
// @ts-expect-error Bun's text loader embeds the generated ESM as a string.
import systemPromptExtension from "../../../dist/extensions/vivi-system-prompt/extension.mjs" with { type: "text" };
// @ts-expect-error Bun's text loader embeds the generated ESM as a string.
import selectionPersistenceExtension from "../../../dist/extensions/vivi-selection-persistence/extension.mjs" with { type: "text" };

export interface PreparedCopilotProfile {
  environment: Record<string, string | undefined>;
  trackChild(pid: number): Promise<void>;
  cleanup(): Promise<void>;
}

export interface PrepareCopilotProfileOptions {
  environment: NodeJS.ProcessEnv;
  configuration: LocalProviderConfiguration;
  selectedModelId?: string;
}

const EXTENSIONS = {
  "vivi-basic-tools": basicToolsExtension,
  "vivi-local-model-policy": localModelPolicyExtension,
  "vivi-reasoning": reasoningExtension,
  "vivi-selection-persistence": selectionPersistenceExtension,
  "vivi-system-prompt": systemPromptExtension,
};

export async function prepareCopilotProfile(
  options: PrepareCopilotProfileOptions,
): Promise<PreparedCopilotProfile> {
  const home = usableHome(options.environment);
  const viviHome = usablePath(options.environment.VIVI_HOME) ?? join(home, ".vivi");
  const copilotHome = join(viviHome, "copilot");
  const runtimeRoot = join(viviHome, "runtime");
  const runtimeDirectory = join(runtimeRoot, `${process.pid}-${crypto.randomUUID()}`);
  const ownerPath = join(runtimeDirectory, "owner.json");
  const providersPath = join(runtimeDirectory, "providers.json");

  await mkdir(viviHome, { recursive: true, mode: 0o700 });
  await mkdir(copilotHome, { recursive: true, mode: 0o700 });
  await mkdir(runtimeRoot, { recursive: true, mode: 0o700 });
  await chmod(viviHome, 0o700).catch(ignoreWindowsPermissionError);
  await chmod(copilotHome, 0o700).catch(ignoreWindowsPermissionError);
  await chmod(runtimeRoot, 0o700).catch(ignoreWindowsPermissionError);
  await reapStaleRuntimeDirectories(runtimeRoot);
  await mkdir(runtimeDirectory, { recursive: true, mode: 0o700 });
  await chmod(runtimeDirectory, 0o700).catch(ignoreWindowsPermissionError);

  await Promise.all(
    Object.entries(EXTENSIONS).map(([name, source]) =>
      writeOwnedFile(join(copilotHome, "extensions", name, "extension.mjs"), source, 0o600),
    ),
  );
  await writeRuntimeOwner(ownerPath, { launcherPid: process.pid, childPid: null });
  await writeOwnedFile(providersPath, `${JSON.stringify(options.configuration, null, 2)}\n`, 0o600);

  const localModelIds = options.configuration.models.map(({ provider, id }) => `${provider}/${id}`);

  return {
    environment: {
      ...options.environment,
      COPILOT_HOME: copilotHome,
      COPILOT_PROVIDERS_CONFIG: providersPath,
      VIVI_LOCAL_MODEL_IDS: JSON.stringify(localModelIds),
      VIVI_SELECTED_MODEL_ID: options.selectedModelId,
      VIVI_SETTINGS_PATH: join(viviHome, "settings.json"),
    },
    trackChild: async (pid) => {
      await writeRuntimeOwner(ownerPath, { launcherPid: process.pid, childPid: pid });
    },
    cleanup: async () => {
      await rm(runtimeDirectory, { recursive: true, force: true });
    },
  };
}

interface RuntimeOwner {
  launcherPid: number;
  childPid: number | null;
}

async function reapStaleRuntimeDirectories(runtimeRoot: string): Promise<void> {
  const entries = await readdir(runtimeRoot, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const match = /^([1-9]\d*)-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.exec(
      entry.name,
    );
    if (match === null) continue;

    const runtimeDirectory = join(runtimeRoot, entry.name);
    const fallbackLauncherPid = Number(match[1]);
    const owner = await readRuntimeOwner(join(runtimeDirectory, "owner.json"), fallbackLauncherPid);
    if (isProcessAlive(owner.launcherPid)) continue;
    if (owner.childPid !== null && isProcessAlive(owner.childPid)) continue;
    await rm(runtimeDirectory, { recursive: true, force: true });
  }
}

async function readRuntimeOwner(path: string, fallbackLauncherPid: number): Promise<RuntimeOwner> {
  try {
    const parsed: unknown = JSON.parse(await readFile(path, "utf8"));
    if (!isRuntimeOwner(parsed)) throw new Error("invalid runtime owner");
    return parsed;
  } catch {
    return { launcherPid: fallbackLauncherPid, childPid: null };
  }
}

function isRuntimeOwner(value: unknown): value is RuntimeOwner {
  if (typeof value !== "object" || value === null) return false;
  const owner = value as Partial<RuntimeOwner>;
  return (
    Number.isSafeInteger(owner.launcherPid) &&
    (owner.launcherPid ?? 0) > 0 &&
    (owner.childPid === null || (Number.isSafeInteger(owner.childPid) && (owner.childPid ?? 0) > 0))
  );
}

function isProcessAlive(pid: number): boolean {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    return !(error instanceof Error && "code" in error && error.code === "ESRCH");
  }
}

async function writeRuntimeOwner(path: string, owner: RuntimeOwner): Promise<void> {
  await writeOwnedFile(path, `${JSON.stringify(owner, null, 2)}\n`, 0o600);
}

async function writeOwnedFile(path: string, content: string, mode: number): Promise<void> {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const existing = await readFile(path, "utf8").catch(() => undefined);
  if (existing === content) return;

  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, content, { encoding: "utf8", mode });
  await chmod(temporary, mode).catch(ignoreWindowsPermissionError);
  try {
    await rename(temporary, path);
  } catch (error) {
    if (process.platform !== "win32") throw error;
    await rm(path, { force: true });
    await rename(temporary, path);
  }
  await chmod(path, mode).catch(ignoreWindowsPermissionError);
}

function usableHome(environment: NodeJS.ProcessEnv): string {
  const home = environment.HOME || environment.USERPROFILE;
  if (home === undefined || home.length === 0) {
    throw new Error("HOME or USERPROFILE is required");
  }
  return home;
}

function usablePath(value: string | undefined): string | undefined {
  return value === undefined || value.length === 0 ? undefined : value;
}

function ignoreWindowsPermissionError(error: unknown): void {
  if (process.platform !== "win32") throw error;
}
