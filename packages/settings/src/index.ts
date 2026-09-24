import { chmod, mkdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";

export const SETTINGS_VERSION = 3;
const MAX_SETTINGS_BYTES = 1024 * 1024;
const REASONING_EFFORTS = new Set(["none", "minimal", "low", "medium", "high", "xhigh", "max"]);
const LEGACY_REASONING_EFFORTS = new Set(["off", "low", "medium", "high", "xhigh", "max"]);

export interface DefaultSelection {
  modelId: string;
  reasoning: string | null;
}

export interface ViviSettings {
  path: string;
  defaultSelection: DefaultSelection | null;
}

interface ParsedSettings extends ViviSettings {
  sourceVersion: number | null;
}

export async function loadAndMigrateViviSettings(
  environment: NodeJS.ProcessEnv,
): Promise<ViviSettings> {
  const path = settingsPath(environment);
  const settings = await loadSettings(path);
  if (settings.sourceVersion !== null && settings.sourceVersion !== SETTINGS_VERSION) {
    await saveDefaultSelection(path, settings.defaultSelection);
  }
  return {
    path,
    defaultSelection: settings.defaultSelection,
  };
}

export async function loadSettings(path: string): Promise<ParsedSettings> {
  const metadata = await stat(path).catch((error: NodeJS.ErrnoException) => {
    if (error.code === "ENOENT") return undefined;
    throw error;
  });
  if (metadata === undefined) {
    return { path, defaultSelection: null, sourceVersion: null };
  }
  if (metadata.size > MAX_SETTINGS_BYTES) {
    throw new Error(`Vivi settings exceed ${MAX_SETTINGS_BYTES} bytes: ${path}`);
  }

  const document = parseDocument(JSON.parse(await readFile(path, "utf8")));
  return {
    path,
    defaultSelection: document.defaultSelection,
    sourceVersion: document.version,
  };
}

export async function saveDefaultSelection(
  path: string,
  defaultSelection: DefaultSelection | null,
): Promise<void> {
  if (defaultSelection !== null) validateSelection(defaultSelection);
  const content = `${JSON.stringify(
    {
      version: SETTINGS_VERSION,
      default_selection:
        defaultSelection === null
          ? null
          : {
              model_id: defaultSelection.modelId,
              reasoning: defaultSelection.reasoning,
            },
      write_id: crypto.randomUUID().replaceAll("-", ""),
    },
    null,
    2,
  )}\n`;

  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await writeFile(temporary, content, { encoding: "utf8", mode: 0o600 });
  await chmod(temporary, 0o600).catch(ignoreWindowsPermissionError);
  try {
    await rename(temporary, path);
  } catch (error) {
    if (process.platform !== "win32") throw error;
    await rm(path, { force: true });
    await rename(temporary, path);
  }
  await chmod(path, 0o600).catch(ignoreWindowsPermissionError);
}

function parseDocument(value: unknown): {
  version: number;
  defaultSelection: DefaultSelection | null;
} {
  const document = record(value, "settings document");
  const version = number(document.version, "settings version");
  validateWriteId(document.write_id);

  if (version === 1) {
    const model = optionalString(document.default_model, "default_model");
    return {
      version,
      defaultSelection:
        model === null ? null : { modelId: normalizeStoredModel(model), reasoning: "none" },
    };
  }
  if (version === 2) {
    return {
      version,
      defaultSelection: parseSelection(document.default_selection, true),
    };
  }
  if (version === SETTINGS_VERSION) {
    return {
      version,
      defaultSelection: parseSelection(document.default_selection, false),
    };
  }
  throw new Error(`Unsupported Vivi settings version: ${version}`);
}

function parseSelection(value: unknown, legacy: boolean): DefaultSelection | null {
  if (value === null || value === undefined) return null;
  const selection = record(value, "default_selection");
  const modelId = normalizeStoredModel(string(selection.model_id, "model_id"));
  if (!legacy && selection.reasoning === null) {
    return { modelId, reasoning: null };
  }
  const reasoning = string(selection.reasoning, "reasoning");
  if (legacy) {
    if (!LEGACY_REASONING_EFFORTS.has(reasoning)) {
      throw new Error(`Invalid legacy Vivi reasoning effort: ${reasoning}`);
    }
    return { modelId, reasoning: reasoning === "off" ? "none" : reasoning };
  }
  if (!REASONING_EFFORTS.has(reasoning)) {
    throw new Error(`Invalid Vivi reasoning effort: ${reasoning}`);
  }
  return { modelId, reasoning };
}

function validateSelection(selection: DefaultSelection): void {
  validateModel(selection.modelId);
  if (selection.reasoning !== null && !REASONING_EFFORTS.has(selection.reasoning)) {
    throw new Error(`Invalid Vivi reasoning effort: ${selection.reasoning}`);
  }
}

function validateModel(value: string): string {
  if (value.length === 0 || value.trim() !== value) {
    throw new Error("Invalid Vivi settings model");
  }
  return value;
}

function normalizeStoredModel(value: string): string {
  validateModel(value);
  return validateModel(value.startsWith("copilot/") ? value.slice("copilot/".length) : value);
}

function validateWriteId(value: unknown): void {
  if (value === null || value === undefined) return;
  const writeId = string(value, "write_id");
  if (!/^[0-9a-f]{32}$/.test(writeId)) {
    throw new Error("Invalid Vivi settings write_id");
  }
}

function settingsPath(environment: NodeJS.ProcessEnv): string {
  const viviHome = environment.VIVI_HOME;
  if (viviHome !== undefined && viviHome.length > 0) {
    return join(viviHome, "settings.json");
  }
  const home = environment.HOME || environment.USERPROFILE;
  if (home === undefined || home.length === 0) {
    throw new Error("HOME or USERPROFILE is required");
  }
  return join(home, ".vivi", "settings.json");
}

function record(value: unknown, name: string): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`Invalid Vivi ${name}`);
  }
  return value as Record<string, unknown>;
}

function string(value: unknown, name: string): string {
  if (typeof value !== "string") throw new Error(`Invalid Vivi ${name}`);
  return value;
}

function optionalString(value: unknown, name: string): string | null {
  if (value === null || value === undefined) return null;
  return string(value, name);
}

function number(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value)) {
    throw new Error(`Invalid Vivi ${name}`);
  }
  return value;
}

function ignoreWindowsPermissionError(error: unknown): void {
  if (process.platform !== "win32") throw error;
}
