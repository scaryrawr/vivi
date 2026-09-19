import { builtinModules } from "node:module";

const forbiddenCorePackages = [
  "@github/copilot-sdk",
  "@opentui/core",
  "electrobun",
];
const nodeBuiltins = new Set(builtinModules.map((moduleName) => moduleName.replace(/^node:/, "")));

export interface BoundaryViolation {
  readonly message: string;
}

const matchesPackage = (source: string, packageName: string): boolean =>
  source === packageName || source.startsWith(`${packageName}/`);

const isNodeBuiltin = (source: string): boolean =>
  nodeBuiltins.has(source.replace(/^node:/, ""));

export function scanText(path: string, text: string): BoundaryViolation[] {
  const normalizedPath = path.replaceAll("\\", "/");
  const violations: BoundaryViolation[] = [];
  const loader = normalizedPath.endsWith(".tsx") ? "tsx" : "ts";
  let imports: ReturnType<Bun.Transpiler["scanImports"]>;
  try {
    imports = new Bun.Transpiler({ loader }).scanImports(text);
  } catch (error) {
    return [{
      message: `${normalizedPath}: failed to parse imports: ${
        error instanceof Error ? error.message : String(error)
      }`,
    }];
  }

  for (const importRecord of imports) {
    const source = importRecord.path;
    const forbiddenInCore =
      isNodeBuiltin(source) ||
      source.startsWith("bun:") ||
      forbiddenCorePackages.some((packageName) => matchesPackage(source, packageName));
    if (normalizedPath.startsWith("packages/core/") && forbiddenInCore) {
      violations.push({ message: `${normalizedPath}: core imports forbidden module "${source}"` });
    }
    if (
      !normalizedPath.startsWith("packages/copilot-adapter/") &&
      matchesPackage(source, "@github/copilot-sdk")
    ) {
      violations.push({ message: `${normalizedPath}: SDK import outside packages/copilot-adapter` });
    }
    if (
      !normalizedPath.startsWith("packages/frontend-opentui/") &&
      matchesPackage(source, "@opentui/core")
    ) {
      violations.push({ message: `${normalizedPath}: OpenTUI import outside packages/frontend-opentui` });
    }
  }
  return violations;
}

export async function scanRepository(root: string): Promise<BoundaryViolation[]> {
  const violations: BoundaryViolation[] = [];
  for await (const path of new Bun.Glob("{apps,packages,scripts}/**/*.{ts,tsx,mts,cts}").scan({ cwd: root, absolute: false })) {
    if (path.includes("/dist/")) continue;
    if (path.startsWith("scripts/") && path.includes(".test.")) continue;
    violations.push(...scanText(path, await Bun.file(`${root}/${path}`).text()));
  }
  return violations;
}

if (import.meta.main) {
  const violations = await scanRepository(process.cwd());
  if (violations.length > 0) {
    console.error(violations.map(({ message }) => message).join("\n"));
    process.exit(1);
  }
  console.log("boundary check passed");
}
