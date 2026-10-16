import { cast, spawn } from "bouy";

class Spinner {
  spin(ms: number): number {
    const end = Date.now() + ms;
    let turns = 0;
    while (Date.now() < end) {
      turns++;
    }
    return turns;
  }
}

class Echo {
  ping(n: number): number {
    return n;
  }
}

async function main(): Promise<void> {
  const spinner = spawn(Spinner);
  const echo = spawn(Echo);
  const started = Date.now();
  cast(spinner).spin(2000);
  let slowest = 0;
  for (let i = 0; i < 50; i++) {
    const sent = Date.now();
    await echo.ping(i);
    slowest = Math.max(slowest, Date.now() - sent);
  }
  const answered = Date.now() - started;
  // Without preemption, a reply would wait for the 2000 ms spin to end.
  console.log(slowest < 500 ? "every reply was fast" : `the slowest reply took ${slowest} ms`);
  console.log(
    answered < 1000 ? "50 replies arrived during the spin" : `50 replies took ${answered} ms`,
  );
}

await main();
