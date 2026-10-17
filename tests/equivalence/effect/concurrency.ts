// Effect.all and Effect.forEach with { concurrency } run the Effects at the same time and
// keep the input order of the results. The order in which the Effects finish proves the
// parallelism, so the output does not depend on the load of the machine: an Effect that
// starts later and sleeps less finishes first only when the two run at once.
import { Effect } from "effect";

const finish = (ms: number, value: string) =>
  Effect.sleep(ms).pipe(
    Effect.tap(() => Effect.sync(() => console.log("  finished", value))),
    Effect.as(value),
  );

console.log("unbounded:");
console.log(
  await Effect.runPromise(
    Effect.all([finish(300, "a"), finish(0, "b")], { concurrency: "unbounded" }),
  ),
);

console.log("forEach:");
console.log(
  await Effect.runPromise(
    Effect.forEach([300, 0], (ms, index) => finish(ms, `#${index}`), { concurrency: 2 }),
  ),
);

console.log("record:");
console.log(
  await Effect.runPromise(
    Effect.all({ slow: finish(300, "S"), fast: finish(0, "F") }, { concurrency: 2 }),
  ),
);

// Two at a time: the third Effect starts when the first one ends, before the second one.
console.log("two at a time:");
await Effect.runPromise(
  Effect.forEach([300, 600, 0], (ms, index) => finish(ms, `#${index}`), {
    concurrency: 2,
    discard: true,
  }),
);

// The failure ends the run at once, so the slow Effect never finishes.
console.log("failure:");
const failed = await Effect.runPromise(
  Effect.result(
    Effect.all([finish(300, "slow"), Effect.fail("fast failure")], { concurrency: "unbounded" }),
  ),
);
console.log(failed._tag, failed._tag === "Failure" ? failed.failure : "");
