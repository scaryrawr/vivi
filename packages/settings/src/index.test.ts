import { afterEach, describe, expect, test } from "bun:test";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { loadAndMigrateViviSettings, loadSettings, saveDefaultSelection } from "./index.ts";

const temporaryDirectories: string[] = [];

afterEach(async () => {
  await Promise.all(
    temporaryDirectories.splice(0).map((path) => rm(path, { recursive: true, force: true })),
  );
});

describe("Vivi settings", () => {
  test("loads and migrates the version 2 selection", async () => {
    const root = await temporaryDirectory();
    const path = join(root, "settings.json");
    await writeFile(
      path,
      JSON.stringify({
        version: 2,
        default_selection: {
          model_id: "omlx/local",
          reasoning: "medium",
        },
        write_id: "1a7dd48496f5b3adaafa6b043dff3845",
      }),
    );

    expect(await loadAndMigrateViviSettings({ VIVI_HOME: root })).toEqual({
      path,
      defaultSelection: {
        modelId: "omlx/local",
        reasoning: "medium",
      },
    });
    expect(JSON.parse(await readFile(path, "utf8"))).toMatchObject({
      version: 3,
      default_selection: {
        model_id: "omlx/local",
        reasoning: "medium",
      },
    });
  });

  test("migrates version 1 hosted model IDs to Copilot's native syntax", async () => {
    const root = await temporaryDirectory();
    const path = join(root, "settings.json");
    await writeFile(
      path,
      JSON.stringify({
        version: 1,
        default_model: "copilot/model",
      }),
    );
    expect((await loadAndMigrateViviSettings({ VIVI_HOME: root })).defaultSelection).toEqual({
      modelId: "model",
      reasoning: "none",
    });
    expect(JSON.parse(await readFile(path, "utf8"))).toMatchObject({
      version: 3,
      default_selection: { model_id: "model", reasoning: "none" },
    });
  });

  test("migrates version 2 hosted model IDs to Copilot's native syntax", async () => {
    const root = await temporaryDirectory();
    const path = join(root, "settings.json");
    await writeFile(
      path,
      JSON.stringify({
        version: 2,
        default_selection: { model_id: "copilot/model", reasoning: "off" },
      }),
    );
    expect((await loadAndMigrateViviSettings({ VIVI_HOME: root })).defaultSelection).toEqual({
      modelId: "model",
      reasoning: "none",
    });
    expect(JSON.parse(await readFile(path, "utf8"))).toMatchObject({
      version: 3,
      default_selection: { model_id: "model", reasoning: "none" },
    });
  });

  test("normalizes stored hosted model IDs without changing local IDs", async () => {
    const root = await temporaryDirectory();
    const path = join(root, "settings.json");
    await writeFile(
      path,
      JSON.stringify({
        version: 3,
        default_selection: { model_id: "copilot/model", reasoning: null },
      }),
    );
    expect((await loadSettings(path)).defaultSelection).toEqual({
      modelId: "model",
      reasoning: null,
    });
    await writeFile(
      path,
      JSON.stringify({
        version: 3,
        default_selection: { model_id: "copilot/", reasoning: null },
      }),
    );
    await expect(loadSettings(path)).rejects.toThrow("Invalid Vivi settings model");
  });

  test("round trips all Copilot reasoning states", async () => {
    const root = await temporaryDirectory();
    const path = join(root, "settings.json");
    for (const reasoning of [null, "none", "minimal", "low", "medium", "high", "xhigh", "max"]) {
      await saveDefaultSelection(path, {
        modelId: "omlx/local",
        reasoning,
      });
      expect((await loadSettings(path)).defaultSelection).toEqual({
        modelId: "omlx/local",
        reasoning,
      });
    }
  });

  test("rejects unsupported versions", async () => {
    const root = await temporaryDirectory();
    const path = join(root, "settings.json");
    await writeFile(path, JSON.stringify({ version: 99 }));
    await expect(loadSettings(path)).rejects.toThrow("Unsupported Vivi settings version: 99");
  });
});

async function temporaryDirectory(): Promise<string> {
  const root = await mkdtemp(join(tmpdir(), "vivi-settings-"));
  temporaryDirectories.push(root);
  return root;
}
