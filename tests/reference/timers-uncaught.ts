// A timer or a tick that throws reaches 'uncaughtException', and the timers due after it
// in the same phase still run.
const order: string[] = [];
process.on("uncaughtException", (error: Error) => order.push(`caught ${error.message}`));
setTimeout(() => {
  order.push("first");
  throw new Error("timer");
}, 10);
setTimeout(() => order.push("second"), 10);
setTimeout(() => {
  order.push("third");
  process.nextTick(() => {
    throw new Error("tick");
  });
}, 10);
setTimeout(() => order.push("fourth"), 10);
setTimeout(() => console.log(order.join(", ")), 500);
