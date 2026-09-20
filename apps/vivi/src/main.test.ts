import { expect, test } from "bun:test";
import { parseCommand } from "./main.js";

test("selects chat for no arguments and explicit chat", () => {
  expect(parseCommand([])).toBe("chat");
  expect(parseCommand(["chat"])).toBe("chat");
});

test("rejects unsupported arguments", () => {
  expect(() => parseCommand(["help"])).toThrow("unsupported command");
  expect(() => parseCommand(["chat", "--model"])).toThrow("unsupported command");
});
