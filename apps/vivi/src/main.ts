import { createSdkCopilotPort } from "@vivi/copilot-adapter";
import { createViviApp } from "@vivi/core";
import { runChat } from "@vivi/frontend-opentui";

export type Command = "chat";

export function parseCommand(argv: readonly string[]): Command {
  if (argv.length === 0 || (argv.length === 1 && argv[0] === "chat")) return "chat";
  throw new Error(`unsupported command: ${argv.join(" ")}`);
}

export async function main(argv: readonly string[]): Promise<void> {
  parseCommand(argv);
  const port = createSdkCopilotPort({ workingDirectory: process.cwd() });
  const app = createViviApp(port);
  await runChat({ app });
}

if (import.meta.main) {
  try {
    await main(Bun.argv.slice(2));
    process.exitCode = 0;
  } catch (error) {
    console.error(error);
    process.exitCode = 1;
  }
}
