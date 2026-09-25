import { chmod, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import packageMetadata from "../package.json";
import { buildExtensions } from "./build-extensions.ts";

const repositoryRoot = join(import.meta.dir, "..");
const target = option("--target");
const output =
  option("--outfile") ??
  join(
    repositoryRoot,
    "dist",
    target?.startsWith("bun-windows") || process.platform === "win32" ? "vivi.exe" : "vivi",
  );
const version = option("--version") ?? packageMetadata.version;

await buildExtensions();
await mkdir(dirname(output), { recursive: true });
const result = await Bun.build({
  entrypoints: [join(repositoryRoot, "apps/vivi/src/main.ts")],
  compile: {
    outfile: output,
    autoloadBunfig: false,
    autoloadDotenv: false,
    ...(target === undefined ? {} : { target: compileTarget(target) }),
  },
  define: {
    VIVI_VERSION: JSON.stringify(version),
  },
  minify: true,
  sourcemap: "linked",
});

if (!result.success) {
  for (const log of result.logs) process.stderr.write(`${log}\n`);
  process.exit(1);
}
if (process.platform !== "win32") await chmod(output, 0o755);
process.stdout.write(`${output}\n`);

function option(name: string): string | undefined {
  const prefix = `${name}=`;
  const match = process.argv.slice(2).find((argument) => argument.startsWith(prefix));
  return match?.slice(prefix.length);
}

function compileTarget(value: string): Bun.Build.CompileTarget {
  const targets: Bun.Build.CompileTarget[] = [
    "bun-darwin-arm64",
    "bun-darwin-x64",
    "bun-linux-arm64",
    "bun-linux-x64",
    "bun-linux-x64-baseline",
    "bun-linux-arm64-musl",
    "bun-linux-x64-musl",
    "bun-windows-arm64",
    "bun-windows-x64",
    "bun-windows-x64-baseline",
  ];
  if (!targets.includes(value as Bun.Build.CompileTarget)) {
    throw new Error(`unsupported Bun compile target: ${value}`);
  }
  return value as Bun.Build.CompileTarget;
}
