// Compute, plain Node: fib(27) by naive recursion inside one mailbox actor from
// node-actor.ts, 20 calls in sequence. No worker_threads.
import { Actor } from "../node-actor.ts";

const N = 27;
const ROUNDS = 20;

function fib(n: number): number {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

class Calculator {
  fibonacci(n: number): number {
    return fib(n);
  }
}

async function measure(): Promise<object> {
  const calculator = new Actor(() => new Calculator());
  let value: unknown = 0;
  const started = performance.now();
  for (let i = 0; i < ROUNDS; i++) {
    value = await calculator.call("fibonacci", N);
  }
  const total = performance.now() - started;
  if (value !== 196418) throw new Error(`fib(${N}) gave ${value}`);
  return { fib_ms: total / ROUNDS };
}

console.log(JSON.stringify(await measure()));
