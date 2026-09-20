import { compareFixture, type FirstMismatch, type ParityResult } from "./index.js";

export interface CompiledHelpFixture {
  readonly name: string;
  readonly argv: readonly string[];
  readonly expected: {
    readonly commandNames: readonly string[];
    readonly stdout: string;
    readonly stderr: string;
    readonly exitStatus: number;
  };
}

export interface CompiledArtifactSpec {
  readonly label: "zig" | "bun";
  readonly requestedPath: string;
  readonly buildCommand: readonly string[];
}

export interface ArtifactIdentity {
  readonly label: CompiledArtifactSpec["label"];
  readonly buildCommand: readonly string[];
  readonly requestedPath: string;
  readonly resolvedPath: string;
  readonly byteLength: number;
  readonly sha256: string;
  readonly fileId: string;
  readonly executable: boolean;
}

export interface ArtifactOutput {
  readonly exitStatus: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

export interface ArtifactRun {
  readonly identity: ArtifactIdentity;
  readonly argv: readonly string[];
  readonly output: ArtifactOutput;
  readonly commandNames: readonly string[];
}

export interface CompiledParityReport extends ParityResult {
  readonly zig?: ArtifactRun;
  readonly bun?: ArtifactRun;
  readonly reason?: string;
}

export interface BuildEvidence {
  readonly ok: boolean;
  readonly details?: string;
}

export interface CompiledParityDependencies {
  readonly build: (artifact: CompiledArtifactSpec) => Promise<BuildEvidence>;
  readonly identify: (artifact: CompiledArtifactSpec) => Promise<ArtifactIdentity>;
  readonly execute: (
    identity: ArtifactIdentity,
    argv: readonly string[],
  ) => Promise<ArtifactOutput>;
}

export async function runCompiledHelpParity(
  fixture: CompiledHelpFixture,
  artifacts: readonly [CompiledArtifactSpec, CompiledArtifactSpec],
  dependencies: CompiledParityDependencies,
): Promise<CompiledParityReport> {
  const identities: ArtifactIdentity[] = [];
  for (const artifact of artifacts) {
    const build = await dependencies.build(artifact);
    if (!build.ok) {
      return inconclusive(fixture.name, build.details ?? `${artifact.label} build failed`);
    }
    try {
      identities.push(await dependencies.identify(artifact));
    } catch (error) {
      return inconclusive(fixture.name, errorMessage(error));
    }
  }

  if (identities.some((identity) => !identity.executable)) {
    return inconclusive(fixture.name, "compiled artifact is not executable");
  }
  if (
    identities[0].resolvedPath === identities[1].resolvedPath ||
    identities[0].fileId === identities[1].fileId ||
    identities[0].sha256 === identities[1].sha256
  ) {
    return inconclusive(fixture.name, "compiled artifacts have identical identity");
  }

  const runs: ArtifactRun[] = [];
  for (let index = 0; index < identities.length; index++) {
    const identity = identities[index];
    let currentIdentity: ArtifactIdentity;
    try {
      currentIdentity = await dependencies.identify(artifacts[index]);
    } catch (error) {
      return inconclusive(fixture.name, errorMessage(error));
    }
    if (!sameIdentity(identity, currentIdentity)) {
      return inconclusive(fixture.name, `${identity.label} artifact identity changed before spawn`);
    }
    let output: ArtifactOutput;
    try {
      output = await dependencies.execute(identity, fixture.argv);
    } catch (error) {
      return inconclusive(fixture.name, errorMessage(error));
    }
    if (output.exitStatus === null) {
      return inconclusive(fixture.name, `${identity.label} process did not exit`);
    }
    let commandNames: readonly string[];
    try {
      commandNames = extractCommandNames(normalizeLineEndings(output.stdout));
    } catch (error) {
      return inconclusive(fixture.name, errorMessage(error));
    }
    runs.push({
      identity,
      argv: fixture.argv,
      output: {
        ...output,
        stdout: normalizeLineEndings(output.stdout),
        stderr: normalizeLineEndings(output.stderr),
      },
      commandNames,
    });
  }

  const expected = {
    exitStatus: fixture.expected.exitStatus,
    stdout: { lines: normalizeLineEndings(fixture.expected.stdout).split("\n") },
    stderr: { lines: normalizeLineEndings(fixture.expected.stderr).split("\n") },
    commandNames: fixture.expected.commandNames,
  };
  const zigComparison = compareFixture(
    fixture.name,
    expected,
    comparableRun(runs[0]),
  );
  if (zigComparison.status === "FAIL") {
    return { ...zigComparison, zig: runs[0], bun: runs[1] };
  }
  const bunComparison = compareFixture(
    fixture.name,
    expected,
    comparableRun(runs[1]),
  );
  if (bunComparison.status === "FAIL") {
    return { ...bunComparison, zig: runs[0], bun: runs[1] };
  }
  const pairComparison = compareFixture(
    fixture.name,
    comparableRun(runs[0]),
    comparableRun(runs[1]),
  );
  if (pairComparison.status === "FAIL") {
    return { ...pairComparison, zig: runs[0], bun: runs[1] };
  }
  return { status: "PASS", fixture: fixture.name, zig: runs[0], bun: runs[1] };
}

export function normalizeLineEndings(value: string): string {
  return value.replace(/\r\n?/g, "\n");
}

export function extractCommandNames(helpText: string): readonly string[] {
  const lines = helpText.split("\n");
  const header = lines.indexOf("Commands:");
  if (header < 0) throw new Error("help output has no Commands: section");
  const names: string[] = [];
  for (const line of lines.slice(header + 1)) {
    if (line === "") break;
    const match = /^ {2}([^\s]+) {2,}\S.*$/.exec(line);
    if (!match) throw new Error(`invalid command line: ${JSON.stringify(line)}`);
    names.push(match[1]);
  }
  if (names.length === 0) throw new Error("help output has no commands");
  return names;
}

function comparableRun(run: ArtifactRun): unknown {
  return {
    exitStatus: run.output.exitStatus,
    stdout: { lines: run.output.stdout.split("\n") },
    stderr: { lines: run.output.stderr.split("\n") },
    commandNames: run.commandNames,
  };
}

function inconclusive(fixture: string, reason: string): CompiledParityReport {
  return { status: "INCONCLUSIVE", fixture, reason };
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

function sameIdentity(left: ArtifactIdentity, right: ArtifactIdentity): boolean {
  return (
    left.resolvedPath === right.resolvedPath &&
    left.byteLength === right.byteLength &&
    left.sha256 === right.sha256 &&
    left.fileId === right.fileId &&
    left.executable === right.executable
  );
}
