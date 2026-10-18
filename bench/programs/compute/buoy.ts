import { spawn } from "buoy";

// Compute: fib(27) by naive recursion inside one actor, 20 calls in sequence. This
// measures the speed of compiled code, where the V8 JIT of Node is expected to win.

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
  const calculator = spawn(Calculator);
  let value = 0;
  const started = Date.now();
  for (let i = 0; i < ROUNDS; i++) {
    value = await calculator.fibonacci(N);
  }
  const total = Date.now() - started;
  if (value !== 196418) throw new Error(`fib(${N}) gave ${value}`);
  return { fib_ms: total / ROUNDS };
}

console.log(JSON.stringify(await measure()));
