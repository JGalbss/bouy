// Effect.try, Effect.tryPromise, and Effect.promise turn exceptions into failures or defects.
import { Effect } from "effect";

const parse = (text: string) =>
  Effect.try({
    try: () => JSON.parse(text) as unknown,
    catch: (error) => `cannot parse ${text}: ${(error as Error).name}`,
  });

console.log(Effect.runSync(parse('{"a":1}')));
const unparsed = Effect.runSync(Effect.result(parse("{oops")));
console.log(unparsed._tag, unparsed._tag === "Failure" ? unparsed.failure : undefined);

const unknown = Effect.runSync(
  Effect.result(
    Effect.try(() => {
      throw new Error("tried and failed");
    }),
  ),
);
if (unknown._tag === "Failure") {
  const failure = unknown.failure;
  console.log(failure._tag, failure.name, failure.message);
  console.log(String(failure.cause));
}

console.log(Effect.runSync(Effect.try(() => 5)));

async function fetchNumber(n: number): Promise<number> {
  if (n < 0) {
    throw new Error(`negative: ${n}`);
  }
  return n * 2;
}

console.log(await Effect.runPromise(Effect.promise(() => fetchNumber(21))));
console.log(await Effect.runPromise(Effect.tryPromise(() => fetchNumber(4))));
const rejected = await Effect.runPromise(Effect.result(Effect.tryPromise(() => fetchNumber(-1))));
if (rejected._tag === "Failure") {
  console.log(rejected.failure._tag, rejected.failure.message, String(rejected.failure.cause));
}
const mapped = await Effect.runPromise(
  Effect.result(
    Effect.tryPromise({
      try: () => fetchNumber(-2),
      catch: (error) => ({ reason: String(error) }),
    }),
  ),
);
console.log(mapped._tag, mapped._tag === "Failure" ? mapped.failure : undefined);

try {
  await Effect.runPromise(Effect.promise(() => fetchNumber(-3)));
} catch (error) {
  console.log("a rejected Effect.promise is a defect:", String(error));
}
