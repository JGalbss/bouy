// Multicore throughput on Bun and Node: start N worker threads that each run one kernel
// file once, with no warm-up, at the given size, and time from the first start to the last
// exit. Each worker prints the JSON line of its kernel, and this program prints one JSON
// line last. Usage: workers.ts <kernel.ts> <workers> <size>
import { Worker } from "node:worker_threads";
import { availableParallelism } from "node:os";

const [kernel = "", count = String(availableParallelism()), size = "1"] = process.argv.slice(2);
const workers = Number(count);
const start = performance.now();
const exits = Array.from(
  { length: workers },
  () =>
    new Promise<void>((resolve, reject) => {
      const worker = new Worker(kernel, { argv: ["0", "1", size] });
      worker.on("error", reject);
      worker.on("exit", (code) => {
        if (code === 0) resolve();
        else reject(new Error(`worker exited with ${code}`));
      });
    }),
);
await Promise.all(exits);
const wallMs = performance.now() - start;
console.log(
  JSON.stringify({
    kernel,
    workers,
    size: Number(size),
    wall_ms: wallMs,
    units_per_s: (workers * Number(size) * 1000) / wallMs,
  }),
);
