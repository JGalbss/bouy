// Effect.race returns the first success. A failure loses to a later success, and when both
// fail, the race fails with the first failure.
import { Console, Effect } from "effect";

const after = (ms: number, value: string) => Effect.sleep(ms).pipe(Effect.as(value));
const failAfter = (ms: number, error: string) =>
  Effect.sleep(ms).pipe(Effect.andThen(Effect.fail(error)));

console.log(await Effect.runPromise(Effect.race(after(300, "slow"), after(20, "fast"))));
console.log(await Effect.runPromise(after(20, "first").pipe(Effect.race(after(300, "second")))));
console.log(
  await Effect.runPromise(Effect.race(Effect.fail("quick failure"), after(50, "later success"))),
);

const bothFail = await Effect.runPromise(
  Effect.result(Effect.race(failAfter(200, "late"), failAfter(10, "early"))),
);
console.log(bothFail._tag, bothFail._tag === "Failure" ? bothFail.failure : "");

const loser = Effect.gen(function* () {
  yield* Effect.sleep(400);
  yield* Console.log("the loser must not finish");
  return "loser";
});
console.log(await Effect.runPromise(Effect.race(loser, after(20, "winner"))));
await Effect.runPromise(Effect.sleep(600));
console.log("the loser was interrupted");
