import { spawn } from "bouy";

// Call latency: 100,000 sequential request/reply calls to one actor. Bouy has no clock
// finer than Date.now(), so the program reports the mean from the total time, and the
// slowest call in whole milliseconds.

const CALLS = 100000;

class Echo {
  ping(n: number): number {
    return n;
  }
}

async function measure(): Promise<object> {
  const echo = spawn(Echo);
  let slowest = 0;
  let answered = 0;
  const started = Date.now();
  for (let i = 0; i < CALLS; i++) {
    const sent = Date.now();
    answered += await echo.ping(1);
    slowest = Math.max(slowest, Date.now() - sent);
  }
  const total = Date.now() - started;
  if (answered !== CALLS) throw new Error(`${answered} of ${CALLS} calls answered`);
  return { mean_us: (total * 1000) / CALLS, max_ms: slowest };
}

console.log(JSON.stringify(await measure()));
