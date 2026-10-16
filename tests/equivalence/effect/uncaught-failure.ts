// A failure that reaches the top level ends the program with status 1, as an unhandled
// rejection ends Node.
import { Data, Effect } from "effect";

class Fatal extends Data.TaggedError("Fatal")<{ readonly reason: string }> {}

console.log("before the failure");
await Effect.runPromise(Effect.fail(new Fatal({ reason: "nobody handles this" })));
console.log("never printed");
