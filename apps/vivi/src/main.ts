import { createSdkCopilotPort } from "@vivi/copilot-adapter";
import { createViviApp } from "@vivi/core";
import { runChat } from "@vivi/frontend-opentui";

export type Command = "chat" | "help";

export function parseCommand(argv: readonly string[]): Command {
  if (argv.length === 0 || (argv.length === 1 && argv[0] === "chat")) return "chat";
  if (argv.length === 1 && (argv[0] === "--help" || argv[0] === "-h")) return "help";
  throw new Error(`unsupported command: ${argv.join(" ")}`);
}

export async function main(argv: readonly string[]): Promise<void> {
  const command = parseCommand(argv);
  if (command === "help") {
    process.stdout.write(
      "Usage: vivi [--help] [--version] [models] [chat] [--model MODEL] [--reasoning LEVEL]\n\n" +
        "Vivi command-line interface. Running vivi with no command starts chat.\n\n" +
        "Commands:\n" +
        "  models     List available Copilot and OMLX models.\n" +
        "  chat       Start an interactive streaming Vivi chat.\n\n",
    );
    return;
  }
  const port = createSdkCopilotPort({ workingDirectory: process.cwd() });
  const app = createViviApp(port);
  await runChat({ app, forceExit: (code) => process.exit(code) });
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
