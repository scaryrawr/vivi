export type ViviCommand =
  | { kind: "help" }
  | { kind: "version" }
  | { kind: "models"; json: boolean }
  | { kind: "launch"; args: string[] };

export interface DefaultSelection {
  modelId: string;
  reasoning: string | null;
}

const COPILOT_COMMANDS = new Set([
  "app",
  "completion",
  "help",
  "init",
  "instruction",
  "login",
  "logout",
  "lsp",
  "mcp",
  "memories",
  "plugin",
  "sessions",
  "skill",
  "update",
  "version",
  "workflow",
]);

const OPTIONS_WITH_VALUES = new Set([
  "-C",
  "-i",
  "-n",
  "-p",
  "--add-dir",
  "--add-github-mcp-tool",
  "--add-github-mcp-toolset",
  "--additional-mcp-config",
  "--agent",
  "--attachment",
  "--auto-tier",
  "--context",
  "--disable-mcp-server",
  "--extension-sdk-path",
  "--interactive",
  "--log-dir",
  "--log-level",
  "--max-autopilot-continues",
  "--mode",
  "--model",
  "--name",
  "--output-format",
  "--plugin-dir",
  "--prompt",
  "--reasoning-effort",
  "--session-id",
  "--stream",
]);

const OPTIONS_WITH_OPTIONAL_VALUES = new Set(["--bash-env", "--mouse", "--share"]);
const OPTIONS_WITH_MULTIPLE_VALUES = new Set([
  "--allow-tool",
  "--allow-url",
  "--available-tools",
  "--deny-tool",
  "--deny-url",
  "--excluded-tools",
  "--secret-env-vars",
]);

export function parseArguments(args: string[]): ViviCommand {
  if (args.length === 0) return { kind: "launch", args: [] };
  if (args.length === 1 && (args[0] === "--help" || args[0] === "-h")) {
    return { kind: "help" };
  }
  if (args.length === 1 && (args[0] === "--version" || args[0] === "-V")) {
    return { kind: "version" };
  }
  if (args[0] === "models") {
    if (args.length === 1) return { kind: "models", json: false };
    if (args.length === 2 && args[1] === "--json") {
      return { kind: "models", json: true };
    }
    throw new Error("Usage: vivi models [--json]");
  }

  return { kind: "launch", args: [...args] };
}

export function applyDefaultSelection(
  args: string[],
  selection: DefaultSelection | null,
): string[] {
  if (selection === null || doesNotStartSession(args) || resumesSession(args)) {
    return args;
  }

  const hasModel = hasOption(args, "--model");
  const hasReasoning = hasOption(args, "--reasoning-effort");
  const defaults: string[] = [];
  if (!hasModel) {
    defaults.push("--model", selection.modelId);
  }
  if (!hasModel && !hasReasoning && selection.reasoning !== null) {
    defaults.push("--reasoning-effort", selection.reasoning);
  }
  return [...defaults, ...args];
}

export function enableBundledExtensions(args: string[]): string[] {
  if (hasOption(args, "--no-experimental")) {
    throw new Error("Vivi requires Copilot's experimental extension runtime");
  }
  if (hasOption(args, "--experimental")) return args;
  return ["--experimental", ...args];
}

function hasOption(args: string[], option: string): boolean {
  for (const argument of args) {
    if (argument === "--") return false;
    if (argument === option || argument.startsWith(`${option}=`)) return true;
  }
  return false;
}

function resumesSession(args: string[]): boolean {
  for (const argument of args) {
    if (argument === "--") return false;
    if (
      argument === "--resume" ||
      argument === "-r" ||
      argument === "--continue" ||
      argument === "--connect" ||
      argument === "--session-id" ||
      argument.startsWith("--resume=") ||
      argument.startsWith("--connect=") ||
      argument.startsWith("--session-id=")
    ) {
      return true;
    }
  }
  return false;
}

function doesNotStartSession(args: string[]): boolean {
  for (let index = 0; index < args.length; index++) {
    const argument = args[index];
    if (argument === undefined) break;
    if (argument === "--") return false;
    if (OPTIONS_WITH_VALUES.has(argument)) {
      index++;
      continue;
    }
    if (OPTIONS_WITH_OPTIONAL_VALUES.has(argument) || OPTIONS_WITH_MULTIPLE_VALUES.has(argument)) {
      while (true) {
        const next = args[index + 1];
        if (next === undefined || next.startsWith("-")) break;
        index++;
        if (!OPTIONS_WITH_MULTIPLE_VALUES.has(argument)) break;
      }
      continue;
    }
    if (argument.startsWith("-")) continue;
    return COPILOT_COMMANDS.has(argument);
  }
  return false;
}
