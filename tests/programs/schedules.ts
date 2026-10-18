import {
  cancelSchedule,
  cast,
  inspect,
  schedule,
  self,
  sleep,
  spawn,
  withTimeout,
  type Ref,
} from "buoy";

// Timers: a delay beyond 2^32 ms is valid, cancelSchedule() returns after the
// timer stops, a full mailbox skips a tick whatever its overflow, and a timer
// ends with the actor that created it, also from inside Promise.all.

class Planner {
  #plans = 0;

  plan(days: number): number {
    schedule(self(this), { after: days * 24 * 3600 * 1000 }, "remind");
    this.#plans++;
    return this.#plans;
  }

  remind(): void {}

  plans(): number {
    return this.#plans;
  }
}

class Ticker {
  #ticks = 0;

  block(ms: number): void {
    sleep(ms);
  }

  tick(): void {
    this.#ticks++;
  }

  ticks(): number {
    return this.#ticks;
  }
}

class Owner {
  armViaAll(ticker: Ref<Ticker>): void {
    Promise.all([ticker].map((target) => schedule(target, { every: 20 }, "tick")));
  }

  boom(): void {
    throw new Error("owner boom");
  }
}

async function main(): Promise<void> {
  const planner = spawn(Planner, { name: "planner" });
  await planner.plan(1);
  await planner.plan(60);
  await sleep(100);
  const entry = inspect().find((actor) => actor.name === "planner");
  console.log(`a 60-day timer: plans ${await planner.plans()}, restarts ${entry?.restarts}`);
  console.log(`withTimeout beyond 2^32 ms: ${await withTimeout(5_000_000_000, () => "fast")}`);

  const ticker = spawn(Ticker);
  let late = 0;
  for (let i = 0; i < 30; i++) {
    const handle = schedule(ticker, { every: 1 }, "tick");
    await sleep(3);
    cancelSchedule(handle);
    const before = await ticker.ticks();
    await sleep(5);
    if ((await ticker.ticks()) !== before) late++;
  }
  console.log(`ticks after cancelSchedule returned: ${late}`);
  console.log(schedule(ticker, { after: 1000000 }, "tick"));

  const busy = spawn(Ticker, { name: "busy", mailbox: { capacity: 1 } });
  cast(busy).block(600);
  await sleep(20);
  const handle = schedule(busy, { every: 10 }, "tick");
  await sleep(200);
  const waiting = inspect().find((actor) => actor.name === "busy")?.mailbox;
  cancelSchedule(handle);
  await sleep(700);
  console.log(`a full mailbox skips ticks: mailbox ${waiting}, ticks ${await busy.ticks()}`);

  const counted = spawn(Ticker);
  const owner = spawn(Owner);
  await owner.armViaAll(counted);
  await sleep(100);
  try {
    await owner.boom();
  } catch (error) {}
  const before = await counted.ticks();
  await sleep(200);
  console.log(
    `a timer from Promise.all ends with its actor: ${(await counted.ticks()) - before} ticks`,
  );
}

await main();
