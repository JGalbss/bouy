// From the README of p-queue: run tasks with a concurrency of two, and wait for the queue to
// become idle.
import PQueue from "p-queue";

const queue = new PQueue({ concurrency: 2 });
const log = [];
const task = (name, turns) => async () => {
  log.push(`start ${name}`);
  for (let turn = 0; turn < turns; turn += 1) await Promise.resolve();
  log.push(`end ${name}`);
  return name;
};
const results = await Promise.all([
  queue.add(task("a", 3)),
  queue.add(task("b", 1)),
  queue.add(task("c", 1)),
]);
await queue.onIdle();
console.log(results.join(" "), queue.size, queue.pending);
console.log(log.join(", "));
