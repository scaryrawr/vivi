import type { CopilotPort, CopilotPortEvent } from "@vivi/core";

export class FakeCopilotPort implements CopilotPort {
  constructor(private readonly chunks: readonly string[]) {}

  async *respond(_prompt: string): AsyncIterable<CopilotPortEvent> {
    for (const text of this.chunks) {
      yield { type: "assistant-delta", text };
    }
  }

  async close(): Promise<void> {}
}

export type ParityStatus = "PASS" | "FAIL" | "INCONCLUSIVE";

export interface FirstMismatch {
  readonly path: string;
  readonly expected: unknown;
  readonly actual: unknown;
}

export interface ParityResult {
  readonly status: ParityStatus;
  readonly fixture: string;
  readonly firstMismatch?: FirstMismatch;
}

export function compareFixture(
  fixture: string,
  expected: unknown,
  actual: unknown,
): ParityResult {
  const mismatch = firstMismatch("$", expected, actual);
  if (mismatch === undefined) {
    return { status: "PASS", fixture };
  }
  return {
    status: "FAIL",
    fixture,
    firstMismatch: mismatch,
  };
}

function firstMismatch(path: string, expected: unknown, actual: unknown): FirstMismatch | undefined {
  if (Object.is(expected, actual)) return undefined;
  if (Array.isArray(expected) && Array.isArray(actual)) {
    if (expected.length !== actual.length) {
      return { path: `${path}.length`, expected: expected.length, actual: actual.length };
    }
    for (let index = 0; index < expected.length; index++) {
      const mismatch = firstMismatch(`${path}[${index}]`, expected[index], actual[index]);
      if (mismatch) return mismatch;
    }
    return undefined;
  }
  if (isRecord(expected) && isRecord(actual)) {
    const keys = [...new Set([...Object.keys(expected), ...Object.keys(actual)])].sort();
    for (const key of keys) {
      const mismatch = firstMismatch(`${path}.${key}`, expected[key], actual[key]);
      if (mismatch) return mismatch;
    }
    return undefined;
  }
  return { path, expected, actual };
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
