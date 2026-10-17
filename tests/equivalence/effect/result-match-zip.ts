// result, match, asVoid, and zip.
import { Effect } from "effect";

const ok = Effect.succeed(3);
const bad = Effect.fail("bad");

const okResult = Effect.runSync(Effect.result(ok));
console.log(okResult._tag, okResult._tag === "Success" ? okResult.success : "");
const badResult = Effect.runSync(bad.pipe(Effect.result));
console.log(badResult._tag, badResult._tag === "Failure" ? badResult.failure : "");

const options = {
  onFailure: (error: string) => `failed with ${error}`,
  onSuccess: (value: number) => `succeeded with ${value}`,
};
console.log(Effect.runSync(Effect.match(ok, options)));
console.log(Effect.runSync(bad.pipe(Effect.match(options))));

console.log(Effect.runSync(Effect.asVoid(ok)));
console.log(Effect.runSync(ok.pipe(Effect.asVoid)));

console.log(Effect.runSync(Effect.zip(ok, Effect.succeed("x"))));
console.log(Effect.runSync(ok.pipe(Effect.zip(Effect.succeed(true)))));
const zipped = Effect.runSync(Effect.result(Effect.zip(ok, bad)));
console.log(zipped._tag, zipped._tag === "Failure" ? zipped.failure : undefined);

const logged = (label: string) =>
  Effect.sync(() => {
    console.log("running", label);
    return label;
  });
console.log(Effect.runSync(Effect.zip(logged("first"), logged("second"))));

const sleepThenLog = (value: string, millis: number) =>
  Effect.sleep(millis).pipe(
    Effect.tap(() => Effect.sync(() => console.log("finished", value))),
    Effect.as(value),
  );
// "b" sleeps less, so it finishes before "a" only when the two run at once.
const both = await Effect.runPromise(
  Effect.zip(sleepThenLog("a", 300), sleepThenLog("b", 50), { concurrent: true }),
);
console.log(both);
