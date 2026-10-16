// Effect.all and Effect.forEach with { concurrency } run the Effects at the same time and
// keep the input order of the results. Wall time proves the parallelism.
import { Effect } from "effect";

const delayed = (ms: number, value: string) => Effect.sleep(ms).pipe(Effect.as(value));

const timed = async <A>(label: string, effect: Effect.Effect<A>, under: number) => {
  const started = Date.now();
  const value = await Effect.runPromise(effect);
  const elapsed = Date.now() - started;
  console.log(label, value, elapsed < under ? "in parallel" : `too slow: ${elapsed} ms`);
};

await timed(
  "unbounded:",
  Effect.all([delayed(300, "a"), delayed(100, "b"), delayed(200, "c")], {
    concurrency: "unbounded",
  }),
  550,
);
await timed(
  "forEach:",
  Effect.forEach([300, 300, 300, 300], (ms, index) => delayed(ms, `#${index}`), { concurrency: 4 }),
  750,
);
await timed(
  "record:",
  Effect.all({ left: delayed(300, "L"), right: delayed(300, "R") }, { concurrency: 2 }),
  550,
);

const started = Date.now();
await Effect.runPromise(
  Effect.forEach([200, 200, 200, 200], (ms) => Effect.sleep(ms), { concurrency: 2, discard: true }),
);
const elapsed = Date.now() - started;
console.log("two at a time:", elapsed >= 380 ? "bounded" : `unbounded: ${elapsed} ms`);

const failing = Effect.all(
  [delayed(400, "slow"), Effect.sleep(50).pipe(Effect.andThen(Effect.fail("fast failure")))],
  { concurrency: "unbounded" },
);
const failStarted = Date.now();
const failed = await Effect.runPromise(Effect.result(failing));
const failElapsed = Date.now() - failStarted;
console.log(
  failed._tag,
  failed._tag === "Failure" ? failed.failure : "",
  failElapsed < 350 ? "without waiting" : `waited ${failElapsed} ms`,
);
