// 1,000,000 calls of a method that mutates `this`, inside one actor turn.
// Runs under node (with the shim of tests/reference/shim), `buoy run`, and
// `buoy run --semantics reference`.
import { spawn } from "buoy";

class Sim {
  total = 0;
  calls = 0;

  bump(k: number): number {
    this.total += k;
    this.calls++;
    return this.total;
  }

  run(n: number): number {
    let last = 0;
    for (let i = 0; i < n; i++) {
      last = this.bump(i % 8);
    }
    return last + this.calls;
  }
}

async function main(): Promise<void> {
  const sim = spawn(Sim);
  const N = 1000000;
  const start = Date.now();
  const check = await sim.run(N);
  const end = Date.now();
  console.log(JSON.stringify({ bench: "methods", n: N, total_ms: end - start, check }));
}

await main();
