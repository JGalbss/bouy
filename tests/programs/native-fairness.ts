import { spawn } from "buoy";

// `kernel` is an island, so the native tier runs it as machine code. The code yields to
// the scheduler every 200 us, so on a VM with one scheduler another actor still answers
// while the kernel runs.
function kernel(n: number): number {
  let x = 1;
  for (let i = 0; i < n; i++) x = (x * 48271) % 2147483647;
  return x;
}

class Cruncher {
  crunch(n: number): number {
    return kernel(n);
  }
}

class Echo {
  ping(n: number): number {
    return n;
  }
}

async function main(): Promise<void> {
  const cruncher = spawn(Cruncher);
  const echo = spawn(Echo);
  console.log(await cruncher.crunch(10));
  const started = Date.now();
  const crunched = cruncher.crunch(30_000_000).then((value) => [value, Date.now() - started]);
  let slowest = 0;
  for (let i = 0; i < 50; i++) {
    const sent = Date.now();
    await echo.ping(i);
    slowest = Math.max(slowest, Date.now() - sent);
  }
  const answered = Date.now() - started;
  const [value, took] = await crunched;
  console.log(value);
  // Without preemption, the first reply would wait for the whole kernel.
  console.log(slowest < took / 2 ? "every reply was fast" : `the slowest reply took ${slowest} ms`);
  console.log(
    answered < took ? "50 replies arrived during the kernel" : `50 replies took ${answered} ms`,
  );
}

await main();
