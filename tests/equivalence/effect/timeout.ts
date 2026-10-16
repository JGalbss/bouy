// Effect.timeout fails with TimeoutError when the duration passes first, and the timed-out
// work stops: its later steps never run.
import { Console, Effect } from "effect";

const work = (ms: number, label: string) =>
  Effect.gen(function* () {
    yield* Console.log(`${label} starts`);
    yield* Effect.sleep(ms);
    yield* Console.log(`${label} finishes`);
    return `${label} result`;
  });

console.log(await Effect.runPromise(Effect.timeout(work(20, "quick"), "1 second")));

const late = await Effect.runPromise(
  Effect.result(work(600, "late").pipe(Effect.timeout("150 millis"))),
);
if (late._tag === "Failure") {
  console.log(late.failure._tag, late.failure.name, late.failure.message);
}

await Effect.runPromise(Effect.sleep(700));
console.log("after waiting, the late work printed nothing more");

const failsFirst = await Effect.runPromise(
  Effect.result(Effect.timeout(Effect.fail("failed in time"), 200)),
);
console.log(failsFirst._tag, failsFirst._tag === "Failure" ? failsFirst.failure : "");

const recovered = await Effect.runPromise(
  work(600, "slow").pipe(
    Effect.timeout(150),
    Effect.catchTag("TimeoutError", (error) => Effect.succeed(`recovered: ${error.message}`)),
  ),
);
console.log(recovered);

const longFormat = await Effect.runPromise(
  Effect.result(Effect.timeout(Effect.sleep(5000), 2500 - 2400)),
);
console.log(longFormat._tag === "Failure" ? longFormat.failure.message : "no timeout");
