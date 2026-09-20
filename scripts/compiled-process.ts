export interface ProcessResult {
  readonly exitStatus: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

const TERMINATION_GRACE_MS = 50;
const DRAIN_GRACE_MS = 100;

export async function runBunProcess(
  argv: readonly string[],
  options: { readonly cwd: string; readonly timeoutMs: number },
): Promise<ProcessResult> {
  const child = Bun.spawn([...argv], {
    cwd: options.cwd,
    detached: true,
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = new Response(child.stdout).text();
  const stderr = new Response(child.stderr).text();
  const timeout = new Promise<number | null>((resolve) => {
    const timer = setTimeout(() => {
      void terminateAfterTimeout(child);
      resolve(null);
    }, options.timeoutMs);
    void child.exited.then(() => clearTimeout(timer));
  });
  const exitStatus = await Promise.race([
    child.exited,
    timeout,
  ]);
  const [stdoutText, stderrText] =
    exitStatus === null
      ? await Promise.race([
          Promise.all([stdout, stderr]),
          delay(DRAIN_GRACE_MS).then(() => ["", ""] as const),
        ])
      : await Promise.all([stdout, stderr]);
  return {
    exitStatus,
    stdout: stdoutText,
    stderr: stderrText,
  };
}

async function terminateAfterTimeout(child: Bun.Subprocess<"ignore", "pipe", "pipe">): Promise<void> {
  signalProcessTree(child, "SIGTERM");
  await delay(TERMINATION_GRACE_MS);
  signalProcessTree(child, "SIGKILL");
}

function signalProcessTree(
  child: Bun.Subprocess<"ignore", "pipe", "pipe">,
  signal: NodeJS.Signals,
): void {
  if (process.platform !== "win32") {
    try {
      process.kill(-child.pid, signal);
      return;
    } catch {}
  }
  child.kill(signal);
}

function delay(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
