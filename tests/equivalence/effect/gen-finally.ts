// try/finally with continue, return, and break in a generator body, and yield* of another
// generator function, which returns an Effect when it is called.
import { Console, Effect } from "effect";

const jumps = Effect.gen(function* () {
  let seen = 0;
  for (const x of [1, 2, 3, 4]) {
    try {
      seen += x;
      if (x === 2) continue;
      if (x === 3) return yield* Effect.succeed(`returned at ${x} after ${seen}`);
      yield* Console.log(`body ${x}`);
    } finally {
      yield* Console.log(`finally ${x}, seen ${seen}`);
    }
  }
  return "end";
});
console.log(Effect.runSync(jumps));

const retries = Effect.gen(function* () {
  let attempts = 0;
  while (true) {
    attempts++;
    try {
      if (attempts < 3) {
        throw new Error(`attempt ${attempts}`);
      }
      break;
    } catch (error) {
      yield* Console.log(`caught ${String(error)}`);
    } finally {
      yield* Console.log(`finally after ${attempts}`);
    }
  }
  return attempts;
});
console.log(Effect.runSync(retries));

function* addOne(n: number) {
  const doubled = yield* Effect.succeed(n * 2);
  return doubled + 1;
}

const delegated = Effect.gen(function* () {
  const a = yield* addOne(1);
  const b = yield* Effect.gen(() => addOne(a));
  return [a, b];
});
console.log(Effect.runSync(delegated));
