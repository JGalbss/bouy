import { once } from "node:events";
import { forkEchoChild, startEchoWorker } from "./echo.ts";
import { nanosecondsSince, percentile, repeatInSequence } from "./measure.ts";

const WARMUP = 2_000;
const SAMPLES = 20_000;
const WINDOW = 64;
const MESSAGES_PER_LANE = 1_500;

type Transport = (reply: () => void) => (message: number) => void;

const localTransport =
  (schedule: (run: () => void) => void): Transport =>
  (reply) => {
    const runQueue: Array<Array<number>> = [];
    const mailbox: Array<number> = [];
    return (message) => {
      mailbox.push(message);
      if (mailbox.length > 1) return;
      runQueue.push(mailbox);
      if (runQueue.length > 1) return;
      schedule(() => {
        for (let actor = runQueue.shift(); actor !== undefined; actor = runQueue.shift()) {
          for (let next = actor.shift(); next !== undefined; next = actor.shift()) reply();
        }
      });
    };
  };

const measureRoundTrips = async (transport: Transport) => {
  const pending: Array<() => void> = [];
  const send = transport(() => pending.shift()?.());
  const ask = (): Promise<void> =>
    new Promise((resolve) => {
      pending.push(resolve);
      send(pending.length);
    });
  await repeatInSequence(WARMUP, ask);
  const samples: Array<number> = [];
  await repeatInSequence(SAMPLES, async () => {
    const start = process.hrtime.bigint();
    await ask();
    samples.push(nanosecondsSince(start));
  });
  let timerTicks = 0;
  const timer = setInterval(() => {
    timerTicks += 1;
  }, 1);
  const start = process.hrtime.bigint();
  await Promise.all(Array.from({ length: WINDOW }, () => repeatInSequence(MESSAGES_PER_LANE, ask)));
  const windowNanoseconds = nanosecondsSince(start);
  clearInterval(timer);
  return {
    p50Us: percentile(samples, 0.5) / 1e3,
    p99Us: percentile(samples, 0.99) / 1e3,
    messagesPerSecond: (WINDOW * MESSAGES_PER_LANE) / (windowNanoseconds / 1e9),
    windowMs: windowNanoseconds / 1e6,
    timerTicksDuringWindow: timerTicks,
  };
};

const microtask = await measureRoundTrips(localTransport((run) => queueMicrotask(run)));
const immediate = await measureRoundTrips(
  localTransport((run) => {
    setImmediate(run);
  }),
);

const worker = startEchoWorker();
await once(worker, "online");
const messagePort = await measureRoundTrips((reply) => {
  worker.on("message", reply);
  return (message) => worker.postMessage(message, []);
});
await worker.terminate();

const child = forkEchoChild();
await once(child, "message");
const ipc = await measureRoundTrips((reply) => {
  child.on("message", reply);
  return (message) => child.send(message);
});
child.kill();

const transports = {
  inIsolateMicrotask: microtask,
  inIsolateImmediate: immediate,
  workerMessagePort: messagePort,
  childProcessIpc: ipc,
};

console.log(
  JSON.stringify({
    samples: SAMPLES,
    window: WINDOW,
    windowMessages: WINDOW * MESSAGES_PER_LANE,
    ...Object.fromEntries(
      Object.entries(transports).flatMap(([transport, result]) =>
        Object.entries(result).map(([metric, value]) => [`${transport}.${metric}`, value]),
      ),
    ),
    involuntaryContextSwitches: process.resourceUsage().involuntaryContextSwitches,
  }),
);
