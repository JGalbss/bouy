import { Effect } from "effect";

export const program = Effect.gen(function* () {
  const items = [1, 2].map((item) => {
    yield * Effect.succeed(item);
  });
  return items;
});
