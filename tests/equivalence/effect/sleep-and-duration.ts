// Effect.sleep takes a DurationInput: a number of milliseconds, a string such as
// "100 millis", or a Duration.
import { Duration, Effect } from "effect";

const sleptAtLeast = async (input: Duration.Input, minimum: number) => {
  const started = Date.now();
  await Effect.runPromise(Effect.sleep(input));
  const elapsed = Date.now() - started;
  console.log(
    JSON.stringify(input),
    elapsed >= minimum ? "slept long enough" : `woke after ${elapsed} ms`,
  );
};

await sleptAtLeast(50, 45);
await sleptAtLeast("100 millis", 95);
await sleptAtLeast("0.2 seconds", 195);
await sleptAtLeast(Duration.millis(60), 55);

console.log(Duration.millis(250));
console.log(Duration.seconds(2));
console.log(
  Duration.toMillis("1.5 seconds"),
  Duration.toMillis(Duration.minutes(2)),
  Duration.toMillis(90),
);
console.log(
  Duration.format(Duration.millis(2500)),
  Duration.format(Duration.hours(3)),
  Duration.format(Duration.millis(0)),
);

const sequence = Effect.gen(function* () {
  const started = Date.now();
  yield* Effect.sleep("40 millis");
  yield* Effect.sleep(40);
  return Date.now() - started >= 75;
});
console.log("sleeps add up:", await Effect.runPromise(sequence));

try {
  Effect.runSync(Effect.sleep("soon" as Duration.Input));
} catch (error) {
  console.log("an invalid duration is a defect:", String(error));
}
