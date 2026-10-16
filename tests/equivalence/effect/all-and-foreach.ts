// Effect.all over arrays and records, and Effect.forEach, one at a time: results in input
// order, and the first failure stops the rest.
import { Console, Effect } from "effect";

const step = (label: string, value: number) => Console.log(`run ${label}`).pipe(Effect.as(value));

console.log(Effect.runSync(Effect.all([step("a", 1), step("b", 2), step("c", 3)])));
console.log(Effect.runSync(Effect.all([])));
console.log(Effect.runSync(Effect.all({ alpha: step("alpha", 1), beta: step("beta", 2) })));
console.log(Effect.runSync(Effect.all([step("discarded", 1)], { discard: true })));

const stopped = Effect.all([step("first", 1), Effect.fail("second failed"), step("third", 3)]);
const stoppedResult = Effect.runSync(Effect.result(stopped));
console.log(stoppedResult._tag, stoppedResult._tag === "Failure" ? stoppedResult.failure : "");

console.log(Effect.runSync(Effect.forEach([10, 20, 30], (n, index) => Effect.succeed(n + index))));
console.log(
  Effect.runSync(Effect.forEach(new Set(["x", "y"]), (item) => Effect.succeed(item.toUpperCase()))),
);
const doubled = Effect.forEach((n: number) => Effect.succeed(n * 2));
console.log(Effect.runSync(doubled([4, 5])));
console.log(Effect.runSync(Effect.forEach([1, 2], (n) => step(`each ${n}`, n), { discard: true })));

const firstOdd = Effect.forEach([2, 4, 5, 6], (n) =>
  n % 2 === 0 ? Console.log(`even ${n}`).pipe(Effect.as(n)) : Effect.fail(`odd ${n}`),
);
const oddResult = Effect.runSync(Effect.result(firstOdd));
console.log(oddResult._tag, oddResult._tag === "Failure" ? oddResult.failure : "");
