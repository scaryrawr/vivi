import { expect, test } from "bun:test";
import { runBunProcess } from "./compiled-process.js";

test("returns null status for a timed-out subprocess", async () => {
  const result = await runBunProcess(
    ["bun", "-e", "await Bun.sleep(1000)"],
    { cwd: process.cwd(), timeoutMs: 20 },
  );
  expect(result.exitStatus).toBeNull();
});
