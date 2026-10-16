import { inspect, sleep, spawn, stop, withTimeout } from "bouy";

class Worker {
  work(ms: number): string {
    sleep(ms);
    return "finished";
  }

  ping(): string {
    return "pong";
  }
}

async function stopSoon(worker: any): Promise<string> {
  await sleep(100);
  stop(worker);
  return "stop returned";
}

async function stopDuringTurn(): Promise<void> {
  const worker = spawn(Worker, { name: "worker" });
  const started = Date.now();
  const [turn, stopper] = await Promise.allSettled([worker.work(5000), stopSoon(worker)]);
  const elapsed = Date.now() - started;
  console.log(`the waiting caller got ${turn.reason._tag}: ${turn.reason.message}`);
  console.log(stopper.value);
  console.log(elapsed < 2500 ? "stop ended the turn early" : `stop took ${elapsed} ms`);
  try {
    await worker.ping();
  } catch (error) {
    console.log(`a later call got ${error._tag}`);
  }
  console.log(`status: ${inspect()[0].status}`);
}

async function cancelWithTimeout(): Promise<void> {
  try {
    await withTimeout(100, () => {
      sleep(400);
      console.log("this line never prints: withTimeout killed the function");
      return "late";
    });
  } catch (error) {
    console.log(`${error._tag}: ${error.message}`);
  }
  await sleep(600);
  console.log(`withTimeout returns a value in time: ${await withTimeout(1000, () => "fast")}`);
}

await stopDuringTurn();
await cancelWithTimeout();
