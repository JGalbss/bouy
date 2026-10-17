// setTimeout ordering: by delay, then by creation; microtasks before timers.
// The delays leave room for a loaded machine: a timer phase runs every timer that is due.
const order: string[] = [];
setTimeout(() => order.push("t200"), 200);
setTimeout(() => order.push("t0-a"), 0);
setTimeout(() => {
  order.push("t0-b");
  Promise.resolve().then(() => order.push("micro in t0-b"));
  setTimeout(() => order.push("nested t0"), 0);
}, 0);
setTimeout(() => order.push("t100"), 100);
const cancelled = setTimeout(() => order.push("never"), 1);
clearTimeout(cancelled);
Promise.resolve().then(() => order.push("micro"));
queueMicrotask(() => order.push("queued micro"));
order.push("sync");

let ticks = 0;
const interval = setInterval(() => {
  ticks++;
  order.push(`tick ${ticks}`);
  if (ticks === 3) clearInterval(interval);
}, 300);

setTimeout(() => console.log(order.join(", ")), 1500);
