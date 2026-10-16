import { once } from "node:events";
import { spawn } from "bouy";
import { startEchoWorker } from "../evidence/echo.ts";
import { nanosecondsSince, percentile, repeatInSequence } from "../evidence/measure.ts";
import { PlainActor } from "../plain-actor.ts";
import { report } from "../suite.ts";

const WARMUP = 5_000;
const SAMPLES = 50_000;
const CALLERS = 64;
const CALLS_PER_CALLER = 1_000;

class Echo {
  echo(value: number): number {
    return value;
  }

  async echoLater(value: number): Promise<number> {
    return value;
  }
}

const measureRoundTrips = async (ask: (value: number) => Promise<number>) => {
  await repeatInSequence(WARMUP, async () => {
    await ask(0);
  });
  const samples: Array<number> = [];
  await repeatInSequence(SAMPLES, async () => {
    const start = process.hrtime.bigint();
    await ask(samples.length);
    samples.push(nanosecondsSince(start));
  });
  const start = process.hrtime.bigint();
  await Promise.all(
    Array.from({ length: CALLERS }, () =>
      repeatInSequence(CALLS_PER_CALLER, async () => {
        await ask(1);
      }),
    ),
  );
  return {
    p50Us: percentile(samples, 0.5) / 1e3,
    p99Us: percentile(samples, 0.99) / 1e3,
    callsPerSecond: (CALLERS * CALLS_PER_CALLER * 1e9) / nanosecondsSince(start),
  };
};

const echo = spawn(Echo);
const direct = new Echo();
const plain = new PlainActor(new Echo());
const worker = startEchoWorker();
await once(worker, "online");
const waitingForWorker: Array<(value: number) => void> = [];
worker.on("message", (value: number) => waitingForWorker.shift()?.(value));

report({
  bouySync: await measureRoundTrips((value) => echo.echo(value)),
  bouyAsync: await measureRoundTrips((value) => echo.echoLater(value)),
  directAsync: await measureRoundTrips((value) => direct.echoLater(value)),
  plainActorSync: await measureRoundTrips((value) => plain.ask((target) => target.echo(value))),
  plainActorAsync: await measureRoundTrips((value) =>
    plain.ask((target) => target.echoLater(value)),
  ),
  workerPort: await measureRoundTrips(
    (value) =>
      new Promise<number>((resolve) => {
        waitingForWorker.push(resolve);
        worker.postMessage(value, []);
      }),
  ),
});
await worker.terminate();
