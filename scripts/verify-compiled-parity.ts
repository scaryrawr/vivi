import { createHash } from "node:crypto";
import { realpath, stat } from "node:fs/promises";
import { join } from "node:path";
import {
  runCompiledHelpParity,
  type ArtifactIdentity,
  type ArtifactOutput,
  type CompiledArtifactSpec,
  type CompiledHelpFixture,
} from "../packages/testkit/src/index.js";
import { runBunProcess } from "./compiled-process.js";

const root = process.cwd();
const BUILD_TIMEOUT_MS = 120_000;
const HELP_TIMEOUT_MS = 2_000;
const fixture: CompiledHelpFixture = {
  name: "help",
  argv: ["--help"],
  expected: {
    commandNames: ["models", "chat"],
    stdout:
      "Usage: vivi [--help] [--version] [models] [chat] [--model MODEL] [--reasoning LEVEL]\n\n" +
      "Vivi command-line interface. Running vivi with no command starts chat.\n\n" +
      "Commands:\n" +
      "  models     List available Copilot and OMLX models.\n" +
      "  chat       Start an interactive streaming Vivi chat.\n\n",
    stderr: "",
    exitStatus: 0,
  },
};

const artifacts: readonly [CompiledArtifactSpec, CompiledArtifactSpec] = [
  {
    label: "zig",
    requestedPath: join(root, "zig-out/bin/vivi"),
    buildCommand: ["zig", "build"],
  },
  {
    label: "bun",
    requestedPath: join(root, "apps/vivi/dist/vivi"),
    buildCommand: ["bun", "run", "build:vivi"],
  },
];

const report = await runCompiledHelpParity(fixture, artifacts, {
  build: async (artifact) => {
    try {
      const result = await runBunProcess(artifact.buildCommand, {
        cwd: root,
        timeoutMs: BUILD_TIMEOUT_MS,
      });
      return {
        ok: result.exitStatus === 0,
        details:
          result.exitStatus === 0
            ? undefined
            : `${artifact.label} build did not complete successfully: ${result.stdout}${result.stderr}`,
      };
    } catch (error) {
      return {
        ok: false,
        details: `${artifact.label} build failed: ${errorMessage(error)}`,
      };
    }
  },
  identify: identifyArtifact,
  execute: executeArtifact,
});

console.log(report.status);
console.log(JSON.stringify(report, null, 2));
process.exitCode = report.status === "PASS" ? 0 : 1;

async function identifyArtifact(artifact: CompiledArtifactSpec): Promise<ArtifactIdentity> {
  const resolvedPath = await realpath(artifact.requestedPath);
  const metadata = await stat(resolvedPath);
  const bytes = await Bun.file(resolvedPath).arrayBuffer();
  const sha256 = createHash("sha256").update(Buffer.from(bytes)).digest("hex");
  return {
    label: artifact.label,
    buildCommand: artifact.buildCommand,
    requestedPath: artifact.requestedPath,
    resolvedPath,
    byteLength: metadata.size,
    sha256,
    fileId: `${metadata.dev}:${metadata.ino}`,
    executable: process.platform === "win32" || (metadata.mode & 0o111) !== 0,
  };
}

async function executeArtifact(
  identity: ArtifactIdentity,
  argv: readonly string[],
): Promise<ArtifactOutput> {
  return runBunProcess([identity.resolvedPath, ...argv], {
    cwd: root,
    timeoutMs: HELP_TIMEOUT_MS,
  });
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
