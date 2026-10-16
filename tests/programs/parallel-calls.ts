import { sleep, spawn } from "bouy";

class Sleeper {
  nap(ms: number): number {
    sleep(ms);
    return ms;
  }
}

async function main(): Promise<void> {
  const sleepers = [spawn(Sleeper), spawn(Sleeper), spawn(Sleeper), spawn(Sleeper)];
  const started = Date.now();
  const naps = await Promise.all(sleepers.map((sleeper) => sleeper.nap(300)));
  const elapsed = Date.now() - started;
  console.log(naps);
  // In sequence the four naps take 1200 ms.
  console.log(elapsed < 900 ? "the calls ran in parallel" : `the calls took ${elapsed} ms`);

  const [first, second] = sleepers;
  const pairStarted = Date.now();
  const pair = await Promise.all([first.nap(300), second.nap(300)]);
  const pairElapsed = Date.now() - pairStarted;
  console.log(pair);
  console.log(pairElapsed < 550 ? "the pair ran in parallel" : `the pair took ${pairElapsed} ms`);
}

await main();
