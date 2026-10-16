// A JavaScript try/catch inside Effect.gen sees JavaScript exceptions only. A failed yield*
// abandons the generator: neither its catch nor its finally runs, as in Effect.
import { Data, Effect } from "effect";

class Rejected extends Data.TaggedError("Rejected")<{ readonly reason: string }> {}

const typedFailure = Effect.gen(function* () {
  try {
    yield* Effect.fail(new Rejected({ reason: "typed" }));
    console.log("not reached");
  } catch (error) {
    console.log("the catch must not see a typed failure", error);
  } finally {
    console.log("the finally must not run after a failed yield*");
  }
  return "done";
});
const typed = Effect.runSync(Effect.result(typedFailure));
console.log(typed._tag, typed._tag === "Failure" ? typed.failure.reason : "");

const defect = Effect.gen(function* () {
  try {
    yield* Effect.sync(() => {
      throw new Error("a defect");
    });
  } catch (error) {
    console.log("the catch must not see a defect", error);
  }
  return "done";
});
try {
  Effect.runSync(defect);
} catch (error) {
  console.log("the defect reached runSync:", String(error));
}

const plainThrow = Effect.gen(function* () {
  let attempts = 0;
  try {
    attempts = yield* Effect.succeed(1);
    throw new Error("plain JavaScript");
  } catch (error) {
    console.log("caught", String(error), "after", attempts, "attempt");
  } finally {
    console.log("finally runs for a JavaScript throw");
  }
  try {
    const value = yield* Effect.succeed("ok");
    console.log("try body", value);
  } finally {
    console.log("finally runs after a normal end");
  }
  return attempts + 1;
});
console.log(Effect.runSync(plainThrow));

const rethrown = Effect.gen(function* () {
  yield* Effect.succeed(0);
  throw new Error("escapes the generator");
});
try {
  Effect.runSync(Effect.result(Effect.catch(rethrown, () => Effect.succeed("caught as failure"))));
  console.log("not reached");
} catch (error) {
  console.log(
    "a throw in the body is a defect, which catch and result let through:",
    String(error),
  );
}
