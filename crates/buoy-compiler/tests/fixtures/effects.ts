import { Console, Data, Effect, Schema, pipe } from "effect";

export class NotFound extends Data.TaggedError("NotFound")<{ readonly id: number }> {}

const User = Schema.Struct({ name: Schema.String });

export const find = Effect.fn("find")(function* (id: number) {
  if (id > 9) {
    yield* new NotFound({ id });
  }
  return Schema.decodeUnknownSync(User)({ name: `user ${id}` });
});

export function* steps(ids: number[]) {
  let total = 0;
  for (const id of ids) {
    try {
      const user = yield* find(id);
      total += user.name.length;
    } finally {
      yield* Console.log("visited", id);
    }
  }
  return total;
}

export const program = Effect.gen(function* () {
  const total = yield* Effect.gen(() => steps([1, 2]));
  return yield* pipe(
    Effect.succeed(total),
    Effect.map((n: number) => n * 2),
    Effect.zip(Effect.void),
  );
});
