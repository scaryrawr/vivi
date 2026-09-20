import { expect, test } from "bun:test";
import { parseCommand } from "./main.js";

test("selects chat for no arguments and explicit chat", () => {
  expect(parseCommand([])).toBe("chat");
  expect(parseCommand(["chat"])).toBe("chat");
});

test("selects help for supported help flags", () => {
  expect(parseCommand(["--help"])).toBe("help");
  expect(parseCommand(["-h"])).toBe("help");
});

test("rejects unsupported arguments", () => {
  expect(() => parseCommand(["help"])).toThrow("unsupported command");
  expect(() => parseCommand(["chat", "--model"])).toThrow("unsupported command");
});
