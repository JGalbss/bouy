// Effect.fn("name")(function* (...) {}) builds a function that returns an Effect, with
// optional pipeables that receive the Effect and the arguments.
import { Data, Effect } from "effect";

class TooLarge extends Data.TaggedError("TooLarge")<{ readonly value: number }> {}

const half = Effect.fn("half")(function* (n: number) {
  if (n > 100) {
    return yield* new TooLarge({ value: n });
  }
  return n / 2;
});

console.log(Effect.runSync(half(10)));
const tooLarge = Effect.runSync(Effect.result(half(500)));
console.log(tooLarge._tag, tooLarge._tag === "Failure" ? tooLarge.failure.value : "");

const sumHalves = Effect.fn("sumHalves")(function* (items: number[]) {
  let total = 0;
  for (const item of items) {
    total += yield* half(item);
  }
  return total;
});
console.log(Effect.runSync(sumHalves([2, 4, 6])));

const piped = Effect.fn("piped")(
  function* (a: number, b: number) {
    return a * b;
  },
  Effect.map((product: number) => product + 1),
  (effect, a, b) => Effect.map(effect, (value: number) => `${a} * ${b} + 1 = ${value}`),
);
console.log(Effect.runSync(piped(6, 7)));

const untraced = Effect.fnUntraced(function* (name: string) {
  return `hello ${name}`;
});
console.log(Effect.runSync(untraced("world")));

const anonymous = Effect.fn(function* (x: number) {
  return x + 1;
});
console.log(Effect.runSync(anonymous(1)));

const factorial: (n: number) => Effect.Effect<number> = Effect.fn("factorial")(function* (
  n: number,
) {
  if (n <= 1) {
    return 1;
  }
  return n * (yield* factorial(n - 1));
});
console.log(Effect.runSync(factorial(10)));

const plain = Effect.fn("plain")((n: number) => Effect.succeed(n * 3));
console.log(Effect.runSync(plain(5)));
