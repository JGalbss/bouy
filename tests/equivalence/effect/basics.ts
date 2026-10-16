// Constructors and running: succeed, fail, sync, void, die, runSync, and runPromise.
import { Effect } from "effect";

console.log(Effect.runSync(Effect.succeed(42)));
console.log(Effect.runSync(Effect.sync(() => "computed lazily")));
console.log(Effect.runSync(Effect.void));
const succeeded = Effect.runSync(Effect.result(Effect.succeed([1, 2])));
console.log(succeeded._tag, succeeded._tag === "Success" ? succeeded.success : undefined);
const failed = Effect.runSync(Effect.result(Effect.fail("boom")));
console.log(failed._tag, failed._tag === "Failure" ? failed.failure : undefined);

try {
  Effect.runSync(Effect.fail({ code: 7 }));
} catch (error) {
  console.log("runSync threw the failure:", error);
}

try {
  Effect.runSync(Effect.die("defect"));
} catch (error) {
  console.log("runSync threw the defect:", error);
}

try {
  Effect.runSync(
    Effect.sync(() => {
      throw new Error("thrown in sync");
    }),
  );
} catch (error) {
  console.log("a throw in sync is a defect:", String(error));
}

const lazy = Effect.sync(() => {
  console.log("the thunk runs when the Effect runs");
  return 1;
});
console.log("built, not run");
console.log(Effect.runSync(lazy) + Effect.runSync(lazy));

console.log(await Effect.runPromise(Effect.succeed("from runPromise")));
try {
  await Effect.runPromise(Effect.fail("rejected"));
} catch (error) {
  console.log("runPromise rejected with:", error);
}
