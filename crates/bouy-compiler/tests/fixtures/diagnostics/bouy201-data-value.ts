import { Data } from "effect";

export class Missing extends Data.TaggedError("Missing")<{ id: string }> {}

export function main(): unknown {
  return Data.struct({ id: "7" });
}
