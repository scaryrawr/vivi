import { join } from "node:path";

const root = join(import.meta.dir, "..");
const extensions = [
  "vivi-basic-tools",
  "vivi-local-model-policy",
  "vivi-reasoning",
  "vivi-selection-persistence",
  "vivi-system-prompt",
] as const;

export async function buildExtensions(): Promise<void> {
  for (const name of extensions) {
    const result = await Bun.build({
      entrypoints: [join(root, "extensions", name, "extension.ts")],
      outdir: join(root, "dist", "extensions", name),
      naming: "extension.mjs",
      target: "node",
      format: "esm",
      external: ["@github/copilot-sdk/extension"],
    });
    if (!result.success) {
      for (const log of result.logs) process.stderr.write(`${log}\n`);
      throw new Error(`Failed to bundle ${name}`);
    }
  }
}

if (import.meta.main) await buildExtensions();
