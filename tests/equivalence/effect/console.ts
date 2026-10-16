// Console.log returns an Effect that prints, as console.log does, when it runs.
import { Console, Effect } from "effect";

const greeting = Console.log("hello", "from", "Console", 42, { nested: [1, "two"] });
console.log("the Effect is built but has not printed yet");
Effect.runSync(greeting);
Effect.runSync(greeting);

const program = Effect.gen(function* () {
  yield* Console.log("first");
  console.log("second, from console.log");
  yield* Console.info("third, from Console.info");
  yield* Console.error("to stderr, which the test does not compare");
  yield* Console.log("%s has %d items", "the list", 3);
  return yield* Console.log("the value of Console.log is undefined");
});
console.log(Effect.runSync(program));

await Effect.runPromise(Effect.forEach(["a", "b"], (letter) => Console.log("item", letter)));
