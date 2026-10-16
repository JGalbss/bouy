// Effect.retry runs a failing Effect again as a Schedule or the retry options allow. Each
// attempt prints a line, so the output counts the attempts.
import { Console, Effect, Schedule } from "effect";

const alwaysFails = (label: string) =>
  Effect.gen(function* () {
    yield* Console.log(`${label}: attempt`);
    return yield* Effect.fail(`${label} failed`);
  });

const show = async (label: string, effect: Effect.Effect<unknown, unknown>) => {
  const result = await Effect.runPromise(Effect.result(effect));
  console.log(
    `${label}:`,
    result._tag,
    result._tag === "Failure" ? result.failure : result.success,
  );
};

await show("recurs(2)", Effect.retry(alwaysFails("recurs"), Schedule.recurs(2)));
await show("times 3", alwaysFails("times").pipe(Effect.retry({ times: 3 })));
await show("recurs(0)", Effect.retry(alwaysFails("once"), Schedule.recurs(0)));

const spacedStarted = Date.now();
await show(
  "spaced",
  Effect.retry(alwaysFails("spaced"), { schedule: Schedule.spaced("60 millis"), times: 2 }),
);
const spacedElapsed = Date.now() - spacedStarted;
console.log("spaced waited between attempts:", spacedElapsed >= 115);

const exponentialStarted = Date.now();
await show(
  "exponential",
  alwaysFails("exponential").pipe(
    Effect.retry({ schedule: Schedule.exponential("20 millis"), times: 3 }),
  ),
);
const exponentialElapsed = Date.now() - exponentialStarted;
console.log("exponential waited 20 + 40 + 80 ms:", exponentialElapsed >= 135);

await show(
  "while",
  Effect.retry(alwaysFails("while"), { while: (error) => error !== "while failed", times: 5 }),
);

const deadline = Date.now() + 120;
const eventually = Effect.sync(() => Date.now()).pipe(
  Effect.flatMap((now) => (now < deadline ? Effect.fail("too early") : Effect.succeed("ready"))),
);
await show("until it succeeds", Effect.retry(eventually, Schedule.spaced("30 millis")));

await show(
  "success needs no retry",
  Effect.retry(Console.log("succeeds at once").pipe(Effect.as(1)), Schedule.recurs(5)),
);
