import { Type } from "@sinclair/typebox";
import { Value } from "@sinclair/typebox/value";

const LOCAL_MODEL_IDS = Type.Array(Type.String());

export function parseLocalModelIds(value: string | undefined): string[] {
  if (value === undefined) return [];
  let parsed: unknown;
  try {
    parsed = JSON.parse(value);
  } catch (error) {
    throw new Error("Invalid VIVI_LOCAL_MODEL_IDS JSON", { cause: error });
  }
  if (!Value.Check(LOCAL_MODEL_IDS, parsed)) {
    throw new Error("VIVI_LOCAL_MODEL_IDS must be an array of model IDs");
  }
  return parsed;
}
