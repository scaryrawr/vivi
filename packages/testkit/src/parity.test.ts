import { expect, test } from "bun:test";
import { compareFixture } from "./index.js";

test("reports a literal parity pass", () => {
  expect(compareFixture("chat-stream", ["hello", " world"], ["hello", " world"])).toEqual({
    status: "PASS",
    fixture: "chat-stream",
  });
});

test("reports the first literal parity mismatch", () => {
  expect(compareFixture("chat-stream", ["hello", " world"], ["hello", "world"])).toEqual({
    status: "FAIL",
    fixture: "chat-stream",
    firstMismatch: {
      path: "$[1]",
      expected: " world",
      actual: "world",
      expectedLiteral: '" world"',
      actualLiteral: '"world"',
    },
  });
});

test("renders missing values in mismatch evidence", () => {
  expect(compareFixture("missing-value", { value: "present" }, {})).toEqual({
    status: "FAIL",
    fixture: "missing-value",
    firstMismatch: {
      path: "$.value",
      expected: "present",
      actual: undefined,
      expectedLiteral: '"present"',
      actualLiteral: "undefined",
    },
  });
});
