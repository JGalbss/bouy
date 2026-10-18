// map, flatMap, andThen, and tap, in their data-first and data-last forms, with pipe() and
// .pipe().
import { Effect, pipe } from "effect";

const start = Effect.succeed(5);

console.log(Effect.runSync(Effect.map(start, (n) => n + 1)));
console.log(Effect.runSync(start.pipe(Effect.map((n) => n * 2))));
console.log(Effect.runSync(Effect.flatMap(start, (n) => Effect.succeed(`flat ${n}`))));
console.log(Effect.runSync(start.pipe(Effect.flatMap((n) => Effect.succeed([n, n])))));
console.log(Effect.runSync(Effect.andThen(start, (n) => Effect.succeed(n - 1))));
console.log(Effect.runSync(start.pipe(Effect.andThen(Effect.succeed("replaced")))));
console.log(
  Effect.runSync(
    start.pipe(
      Effect.tap((n) => Effect.sync(() => console.log("tap sees", n))),
      Effect.map((n) => n + 100),
    ),
  ),
);
console.log(
  Effect.runSync(
    Effect.tap(
      start,
      Effect.sync(() => console.log("tap with an Effect")),
    ),
  ),
);

const pipeline = pipe(
  Effect.succeed("buoy"),
  Effect.map((name) => name.toUpperCase()),
  Effect.flatMap((name) => Effect.succeed(`${name}!`)),
  Effect.andThen((text) => Effect.succeed(text.length)),
);
console.log(Effect.runSync(pipeline));

console.log(
  pipe(
    3,
    (n: number) => n + 1,
    (n: number) => n * 10,
    String,
  ),
);
console.log(pipe("unchanged"));

const failing = Effect.fail("stop").pipe(
  Effect.map(() => "mapped"),
  Effect.tap(() => Effect.sync(() => console.log("never"))),
);
const stopped = Effect.runSync(Effect.result(failing));
console.log(stopped._tag, stopped._tag === "Failure" ? stopped.failure : undefined);
