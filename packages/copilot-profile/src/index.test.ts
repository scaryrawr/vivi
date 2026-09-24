import { afterEach, describe, expect, test } from "bun:test";
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { prepareCopilotProfile } from "./index.ts";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((path) => rm(path, { recursive: true, force: true })),
  );
});

describe("prepareCopilotProfile", () => {
  test("materializes owned extensions and removes the runtime registry", async () => {
    const root = await mkdtemp(join(tmpdir(), "vivi-profile-"));
    temporaryDirectories.push(root);
    const profile = await prepareCopilotProfile({
      environment: { HOME: root },
      selectedModelId: "omlx/model",
      configuration: {
        providers: [
          {
            name: "omlx",
            baseUrl: "http://localhost:8000/v1",
            apiKey: "secret",
          },
        ],
        models: [{ id: "model", provider: "omlx" }],
      },
    });

    const copilotHome = join(root, ".vivi", "copilot");
    expect(profile.environment.COPILOT_HOME).toBe(copilotHome);
    expect(profile.environment.VIVI_SETTINGS_PATH).toBe(join(root, ".vivi", "settings.json"));
    expect(profile.environment.VIVI_LOCAL_MODEL_IDS).toBe('["omlx/model"]');
    expect(profile.environment.VIVI_SELECTED_MODEL_ID).toBe("omlx/model");
    expect(
      await readFile(join(copilotHome, "extensions", "vivi-basic-tools", "extension.mjs"), "utf8"),
    ).toContain('name: "read"');
    expect(
      await readFile(
        join(copilotHome, "extensions", "vivi-system-prompt", "extension.mjs"),
        "utf8",
      ),
    ).toContain("joinSession");
    const localPolicy = await readFile(
      join(copilotHome, "extensions", "vivi-local-model-policy", "extension.mjs"),
      "utf8",
    );
    expect(localPolicy).toContain("VIVI_LOCAL_MODEL_IDS must be an array of model IDs");
    expect(localPolicy).not.toContain('from "@sinclair/typebox"');
    expect(
      await readFile(
        join(copilotHome, "extensions", "vivi-selection-persistence", "extension.mjs"),
        "utf8",
      ),
    ).toContain("session.model_change");
    expect(
      await readFile(join(copilotHome, "extensions", "vivi-reasoning", "extension.mjs"), "utf8"),
    ).toContain('name: "reasoning"');

    const providersPath = profile.environment.COPILOT_PROVIDERS_CONFIG;
    expect(providersPath).toBeDefined();
    expect(await readFile(providersPath!, "utf8")).toContain('"apiKey": "secret"');
    if (process.platform !== "win32") {
      expect((await stat(providersPath!)).mode & 0o777).toBe(0o600);
    }

    await profile.trackChild(process.pid);
    expect(JSON.parse(await readFile(join(providersPath!, "..", "owner.json"), "utf8"))).toEqual({
      launcherPid: process.pid,
      childPid: process.pid,
    });

    await profile.cleanup();
    expect(await Bun.file(providersPath!).exists()).toBe(false);
  });

  test("reaps dead runtime owners without touching live launches", async () => {
    const root = await mkdtemp(join(tmpdir(), "vivi-profile-"));
    temporaryDirectories.push(root);
    const runtimeRoot = join(root, ".vivi", "runtime");
    const deadProcess = Bun.spawn([process.execPath, "-e", ""]);
    await deadProcess.exited;

    const deadRuntime = join(runtimeRoot, `${deadProcess.pid}-${crypto.randomUUID()}`);
    const liveRuntime = join(runtimeRoot, `${process.pid}-${crypto.randomUUID()}`);
    await Promise.all([
      createRuntimeDirectory(deadRuntime, deadProcess.pid),
      createRuntimeDirectory(liveRuntime, process.pid),
    ]);

    const profile = await prepareCopilotProfile({
      environment: { HOME: root },
      configuration: { providers: [], models: [] },
    });

    expect(await Bun.file(join(deadRuntime, "providers.json")).exists()).toBe(false);
    expect(await Bun.file(join(liveRuntime, "providers.json")).exists()).toBe(true);
    await profile.cleanup();
  });
});

async function createRuntimeDirectory(path: string, launcherPid: number): Promise<void> {
  await mkdir(path, { recursive: true });
  await Promise.all([
    writeFile(join(path, "owner.json"), `${JSON.stringify({ launcherPid, childPid: null })}\n`),
    writeFile(join(path, "providers.json"), '{"providers":[],"models":[]}\n'),
  ]);
}
