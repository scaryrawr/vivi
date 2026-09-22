import { resolve } from "node:path";
import { prepareCopilotProfile } from "@vivi/copilot-profile";
import { discoverLocalProviders, type ProviderModelConfig } from "@vivi/provider-discovery";
import { loadAndMigrateViviSettings } from "@vivi/settings";
import packageMetadata from "../package.json";
import {
  applyDefaultSelection,
  enableBundledExtensions,
  parseArguments,
  selectedModel,
} from "./arguments.ts";

declare const VIVI_VERSION: string | undefined;
const VERSION = typeof VIVI_VERSION === "string" ? VIVI_VERSION : packageMetadata.version;

const HELP = `Usage: vivi [--help] [--version] [models [--json]] [chat] [COPILOT_OPTIONS]

Vivi discovers local models, installs its bundled Copilot extensions, and
launches GitHub Copilot CLI with an isolated Vivi profile.

Commands:
  models     List discovered local provider models.
  chat       Launch Copilot CLI. This is also the default command.

Compatibility:
  --model copilot/<id> is forwarded as --model <id>.
  --reasoning <level> is forwarded as --reasoning-effort <level>.

All other arguments are passed directly to GitHub Copilot CLI.
`;

try {
  const command = parseArguments(process.argv.slice(2));

  if (command.kind === "help") {
    process.stdout.write(HELP);
    process.exit(0);
  }
  if (command.kind === "version") {
    process.stdout.write(`vivi ${VERSION}\n`);
    process.exit(0);
  }

  const [discovery, settings] = await Promise.all([
    discoverLocalProviders(process.env),
    loadAndMigrateViviSettings(process.env),
  ]);
  if (command.kind === "models") {
    printModels(discovery.models, command.json);
    process.exit(0);
  }

  const copilot = process.env.VIVI_COPILOT_PATH ?? Bun.which("copilot");
  if (copilot === null || copilot === undefined) {
    throw new Error(
      "GitHub Copilot CLI was not found. Install `copilot` or set VIVI_COPILOT_PATH.",
    );
  }

  const childArgs = enableBundledExtensions(
    applyDefaultSelection(command.args, settings.defaultSelection),
  );
  const profile = await prepareCopilotProfile({
    environment: process.env,
    configuration: discovery,
    selectedModelId: selectedModel(childArgs),
  });
  try {
    const child = Bun.spawn([resolve(copilot), ...childArgs], {
      cwd: process.cwd(),
      env: profile.environment,
      stdin: "inherit",
      stdout: "inherit",
      stderr: "inherit",
    });
    try {
      await profile.trackChild(child.pid);
    } catch (error) {
      child.kill();
      await child.exited;
      throw error;
    }
    const signals: NodeJS.Signals[] = ["SIGINT", "SIGTERM"];
    const signalHandlers = new Map(
      signals.map((signal) => [
        signal,
        () => {
          child.kill(signal);
        },
      ]),
    );
    for (const [signal, handler] of signalHandlers) {
      process.on(signal, handler);
    }
    try {
      process.exitCode = await child.exited;
    } finally {
      for (const [signal, handler] of signalHandlers) {
        process.off(signal, handler);
      }
    }
  } finally {
    await profile.cleanup();
  }
} catch (error) {
  process.stderr.write(`vivi: ${error instanceof Error ? error.message : String(error)}\n`);
  process.exitCode = 1;
}

function printModels(models: ProviderModelConfig[], json: boolean): void {
  if (json) {
    process.stdout.write(`${JSON.stringify(models, null, 2)}\n`);
    return;
  }
  if (models.length === 0) {
    process.stdout.write(
      "No local models discovered. Hosted Copilot models remain available through /model.\n",
    );
    return;
  }
  for (const model of models) {
    const supportsVision = model.capabilities?.supports?.vision === true;
    process.stdout.write(
      [
        `${model.provider}/${model.id}`,
        model.name ?? model.id,
        `context=${model.maxContextWindowTokens ?? 0}`,
        `output=${model.maxOutputTokens ?? 0}`,
        `vision=${supportsVision ? "yes" : "no"}`,
      ].join("\t") + "\n",
    );
  }
}
