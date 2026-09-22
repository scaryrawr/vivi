import { describe, expect, test } from "bun:test";
import {
  applyDefaultSelection,
  enableBundledExtensions,
  parseArguments,
  selectedModel,
} from "./arguments.ts";

describe("parseArguments", () => {
  test("launches Copilot by default", () => {
    expect(parseArguments([])).toEqual({ kind: "launch", args: [] });
    expect(parseArguments(["chat"])).toEqual({ kind: "launch", args: [] });
  });

  describe("applyDefaultSelection", () => {
    const selection = {
      modelId: "omlx/local-model",
      reasoning: "medium",
    };

    test("applies the persisted model and reasoning to new sessions", () => {
      expect(applyDefaultSelection([], selection)).toEqual([
        "--model",
        "omlx/local-model",
        "--reasoning-effort",
        "medium",
      ]);
    });

    test("does not override an explicit model selection", () => {
      expect(applyDefaultSelection(["--model", "gpt-5.6-luna"], selection)).toEqual([
        "--model",
        "gpt-5.6-luna",
      ]);
    });

    test("allows an explicit reasoning override for the persisted model", () => {
      expect(applyDefaultSelection(["--reasoning-effort", "high"], selection)).toEqual([
        "--model",
        "omlx/local-model",
        "--reasoning-effort",
        "high",
      ]);
    });

    test("does not override resumed sessions or Copilot subcommands", () => {
      expect(applyDefaultSelection(["--continue"], selection)).toEqual(["--continue"]);
      expect(applyDefaultSelection(["--session-id", "existing-session"], selection)).toEqual([
        "--session-id",
        "existing-session",
      ]);
      expect(applyDefaultSelection(["--session-id=existing-session"], selection)).toEqual([
        "--session-id=existing-session",
      ]);
      expect(applyDefaultSelection(["login"], selection)).toEqual(["login"]);
    });

    test("omits reasoning when the selection uses the model default", () => {
      expect(
        applyDefaultSelection([], {
          modelId: "copilot/gpt-5.6-luna",
          reasoning: null,
        }),
      ).toEqual(["--model", "gpt-5.6-luna"]);
    });
  });

  describe("enableBundledExtensions", () => {
    test("enables Copilot's extension runtime", () => {
      expect(enableBundledExtensions(["--model", "gpt-5.6-luna"])).toEqual([
        "--experimental",
        "--model",
        "gpt-5.6-luna",
      ]);
    });

    test("preserves an explicit experimental flag", () => {
      expect(enableBundledExtensions(["--experimental"])).toEqual(["--experimental"]);
    });

    test("rejects disabling the required extension runtime", () => {
      expect(() => enableBundledExtensions(["--no-experimental"])).toThrow(
        "Vivi requires Copilot's experimental extension runtime",
      );
    });
  });

  describe("selectedModel", () => {
    test("reads the effective Copilot model argument", () => {
      expect(selectedModel(["--experimental", "--model", "omlx/local-model"])).toBe(
        "omlx/local-model",
      );
      expect(selectedModel(["--model=gpt-5.6-luna"])).toBe("gpt-5.6-luna");
      expect(selectedModel(["--", "--model", "omlx/not-an-option"])).toBeUndefined();
    });
  });

  test("translates Vivi model and reasoning arguments", () => {
    expect(
      parseArguments(["chat", "--model", "copilot/gpt-5.6-luna", "--reasoning", "off"]),
    ).toEqual({
      kind: "launch",
      args: ["--model", "gpt-5.6-luna", "--reasoning-effort", "none"],
    });
  });

  test("preserves local provider model identifiers", () => {
    expect(parseArguments(["--model=omlx/Qwen3.5", "--reasoning=high"])).toEqual({
      kind: "launch",
      args: ["--model=omlx/Qwen3.5", "--reasoning-effort=high"],
    });
  });

  test("recognizes local model listing", () => {
    expect(parseArguments(["models"])).toEqual({ kind: "models", json: false });
    expect(parseArguments(["models", "--json"])).toEqual({
      kind: "models",
      json: true,
    });
  });
});
