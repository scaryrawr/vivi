import { describe, expect, test } from "bun:test";
import { applyDefaultSelection, enableBundledExtensions, parseArguments } from "./arguments.ts";

describe("parseArguments", () => {
  test("launches Copilot by default", () => {
    expect(parseArguments([])).toEqual({ kind: "launch", args: [] });
    expect(parseArguments(["chat"])).toEqual({ kind: "launch", args: ["chat"] });
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
      expect(applyDefaultSelection(["--no-auto-update", "login"], selection)).toEqual([
        "--no-auto-update",
        "login",
      ]);
      expect(applyDefaultSelection(["--no-color", "help", "environment"], selection)).toEqual([
        "--no-color",
        "help",
        "environment",
      ]);
      expect(applyDefaultSelection(["--log-level", "login", "help"], selection)).toEqual([
        "--log-level",
        "login",
        "help",
      ]);
      expect(applyDefaultSelection(["--log-level=login", "help"], selection)).toEqual([
        "--log-level=login",
        "help",
      ]);
      expect(
        applyDefaultSelection(
          ["--allow-tool", "login", "help", "--no-color", "sessions"],
          selection,
        ),
      ).toEqual(["--allow-tool", "login", "help", "--no-color", "sessions"]);
      expect(applyDefaultSelection(["--model", "login", "--prompt", "help"], selection)).toEqual([
        "--model",
        "login",
        "--prompt",
        "help",
      ]);
      expect(applyDefaultSelection(["--no-color", "workflow", "list"], selection)).toEqual([
        "--no-color",
        "workflow",
        "list",
      ]);
    });

    test("does not mistake option values for subcommands", () => {
      expect(applyDefaultSelection(["--prompt", "login"], selection)).toEqual([
        "--model",
        "omlx/local-model",
        "--reasoning-effort",
        "medium",
        "--prompt",
        "login",
      ]);
      expect(applyDefaultSelection(["--log-level", "login"], selection)).toEqual([
        "--model",
        "omlx/local-model",
        "--reasoning-effort",
        "medium",
        "--log-level",
        "login",
      ]);
      expect(applyDefaultSelection(["--share", "login"], selection)).toEqual([
        "--model",
        "omlx/local-model",
        "--reasoning-effort",
        "medium",
        "--share",
        "login",
      ]);
    });

    test("omits reasoning when the selection uses the model default", () => {
      expect(
        applyDefaultSelection([], {
          modelId: "gpt-5.6-luna",
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

  test("forwards Copilot arguments without translating their values", () => {
    expect(
      parseArguments(["chat", "--model", "copilot/gpt-5.6-luna", "--reasoning", "off"]),
    ).toEqual({
      kind: "launch",
      args: ["chat", "--model", "copilot/gpt-5.6-luna", "--reasoning", "off"],
    });
  });

  test("preserves local provider model identifiers", () => {
    expect(parseArguments(["--model=omlx/Qwen3.5", "--reasoning=high"])).toEqual({
      kind: "launch",
      args: ["--model=omlx/Qwen3.5", "--reasoning=high"],
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
