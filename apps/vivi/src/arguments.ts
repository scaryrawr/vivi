export type ViviCommand =
  | { kind: "help" }
  | { kind: "version" }
  | { kind: "models"; json: boolean }
  | { kind: "launch"; args: string[] };

export interface DefaultSelection {
  modelId: string;
  reasoning: string | null;
}

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
  const command = args[0];
  return (
    command !== undefined &&
    new Set([
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
    ]).has(command)
  );
}
