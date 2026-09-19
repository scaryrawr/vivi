const forbiddenCorePackages = [
  "@github/copilot-sdk",
  "@opentui/core",
  "electrobun",
  "fs",
  "path",
  "os",
  "tty",
];

export interface BoundaryViolation {
  readonly message: string;
}

const matchesPackage = (source: string, packageName: string): boolean =>
  source === packageName || source.startsWith(`${packageName}/`);

export function scanText(path: string, text: string): BoundaryViolation[] {
  const normalizedPath = path.replaceAll("\\", "/");
  const violations: BoundaryViolation[] = [];
  const imports = [
    ...text.matchAll(/(?:import|export)\s+(?:[^"'`]*?\s+from\s+)?["']([^"']+)["']/g),
    ...text.matchAll(/\bimport\s*\(\s*["']([^"']+)["']\s*\)/g),
    ...text.matchAll(/\brequire\s*\(\s*["']([^"']+)["']\s*\)/g),
  ];
  for (const match of imports) {
    const source = match[1];
    const forbiddenInCore =
      source.startsWith("node:") ||
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
