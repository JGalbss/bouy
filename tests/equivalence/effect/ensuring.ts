// ensuring runs its finalizer after a success, a failure, and a defect, in order.
import { Console, Effect } from "effect";

const finalizer = (label: string) => Console.log(`finalizer of ${label}`);

const succeeded = Effect.succeed("value").pipe(
  Effect.tap(() => Console.log("work succeeds")),
  Effect.ensuring(finalizer("success")),
);
console.log(Effect.runSync(succeeded));

const failed = Effect.ensuring(
  Effect.gen(function* () {
    yield* Console.log("work fails");
    return yield* Effect.fail("failure");
  }),
  finalizer("failure"),
);
const failedResult = Effect.runSync(Effect.result(failed));
console.log(failedResult._tag, failedResult._tag === "Failure" ? failedResult.failure : "");

const died = Effect.die("defect").pipe(Effect.ensuring(finalizer("defect")));
try {
  Effect.runSync(died);
} catch (error) {
  console.log("the defect still escapes:", error);
}

const nested = Effect.succeed(1).pipe(
  Effect.ensuring(finalizer("inner")),
  Effect.flatMap((n) => Effect.fail(n + 1)),
  Effect.ensuring(finalizer("outer")),
);
const nestedResult = Effect.runSync(Effect.result(nested));
console.log(nestedResult._tag, nestedResult._tag === "Failure" ? nestedResult.failure : "");
