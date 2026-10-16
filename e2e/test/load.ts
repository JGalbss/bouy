import { inspect, shutdown, spawn } from "bouy";

const ACTORS = 2_000;
const CALLS_PER_ACTOR = 20;

class Counter {
  #count = 0;

  increment(): number {
    this.#count += 1;
    return this.#count;
  }
}

const startedAt = performance.now();
const counters = Array.from({ length: ACTORS }, () => spawn(Counter));
const replies = await Promise.all(
  counters.map((counter) =>
    Promise.all(Array.from({ length: CALLS_PER_ACTOR }, () => counter.increment())),
  ),
);
const expected = Array.from({ length: CALLS_PER_ACTOR }, (_, index) => index + 1);

console.log(
  JSON.stringify({
    actors: inspect().filter((actor) => actor.name === "Counter").length,
    replies: replies.flat().length,
    everyActorAnsweredInOrder: replies.every((own) =>
      own.every((reply, index) => reply === expected[index]),
    ),
    elapsedMs: performance.now() - startedAt,
  }),
);
await shutdown();
