export interface ProcessResult {
  readonly exitStatus: number | null;
  readonly stdout: string;
  readonly stderr: string;
}

export async function runBunProcess(
  argv: readonly string[],
  options: { readonly cwd: string; readonly timeoutMs: number },
): Promise<ProcessResult> {
  const child = Bun.spawn([...argv], {
    cwd: options.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = new Response(child.stdout).text();
  const stderr = new Response(child.stderr).text();
  const timeout = new Promise<number | null>((resolve) => {
    const timer = setTimeout(() => {
      child.kill();
      resolve(null);
    }, options.timeoutMs);
    void child.exited.then(() => clearTimeout(timer));
  });
  const exitStatus = await Promise.race([
    child.exited,
    timeout,
  ]);
  const [stdoutText, stderrText] = await Promise.all([stdout, stderr]);
  return {
    exitStatus,
    stdout: stdoutText,
    stderr: stderrText,
  };
}
