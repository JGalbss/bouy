// From the README of effect 3: a program built from effects, with a typed failure, a
// recovery, and a schema decode.
import { Data, Effect, Either, Schema, pipe } from "effect";

class NotFound extends Data.TaggedError("NotFound") {}

const find = (id) =>
  id === 1 ? Effect.succeed({ id, name: "Ada" }) : Effect.fail(new NotFound({ id }));
const program = pipe(
  find(2),
  Effect.catchTag("NotFound", (error) => Effect.succeed({ id: error.id, name: "unknown" })),
  Effect.map((user) => `${user.id}: ${user.name}`),
);
console.log(Effect.runSync(program));
console.log(Effect.runSync(Effect.either(find(3))).left._tag);
const result = await Effect.runPromise(
  Effect.gen(function* () {
    const user = yield* find(1);
    return user.name.toUpperCase();
  }),
);
console.log(result);

const User = Schema.Struct({ id: Schema.Number, name: Schema.String });
console.log(JSON.stringify(Schema.decodeUnknownSync(User)({ id: 1, name: "Ada" })));
console.log(Either.isLeft(Schema.decodeUnknownEither(User)({ id: "1" })));
