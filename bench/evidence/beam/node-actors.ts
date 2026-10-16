import { AsyncLocalStorage } from "node:async_hooks";

class Mailbox<Message> implements AsyncIterableIterator<Message> {
  readonly #queue: Message[] = [];
  #waiter: ((result: IteratorResult<Message>) => void) | undefined = undefined;

  send(message: Message): void {
    const waiter = this.#waiter;
    if (waiter === undefined) {
      this.#queue.push(message);
      return;
    }
    this.#waiter = undefined;
    waiter({ done: false, value: message });
  }

  next(): Promise<IteratorResult<Message>> {
    const queued = this.#queue.shift();
    if (queued !== undefined) return Promise.resolve({ done: false, value: queued });
    return new Promise((resolve) => {
      this.#waiter = resolve;
    });
  }

  [Symbol.asyncIterator](): this {
    return this;
  }
}

interface Request {
  readonly replyTo: Mailbox<number>;
  readonly remaining: number;
}

interface Percentiles {
  readonly min: number;
  readonly p50: number;
  readonly p90: number;
  readonly p99: number;
  readonly p999: number;
  readonly max: number;
  readonly mean: number;
}

const collect = globalThis.gc;
if (collect === undefined) throw new Error("Run with node --expose-gc.");

const nanosecondsPerMillisecond = 1e6;

const environment = {
  node: process.version,
  v8: process.versions.v8,
  platform: process.platform,
  arch: process.arch,
};

const percentiles = (milliseconds: Float64Array): Percentiles => {
  const sorted = milliseconds
    .toSorted()
    .map((sample) => Math.round(sample * nanosecondsPerMillisecond));
  const at = (fraction: number): number =>
    sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)] ?? Number.NaN;
  return {
    min: at(0),
    p50: at(0.5),
    p90: at(0.9),
    p99: at(0.99),
    p999: at(0.999),
    max: at(1),
    mean: sorted.reduce((sum, sample) => sum + sample, 0) / sorted.length,
  };
};

const idle = async (inbox: Mailbox<number>): Promise<number> => {
  let total = 0;
  for await (const message of inbox) total += message;
  return total;
};

const storage = new AsyncLocalStorage<number>();

const actorKinds = new Map<string, (index: number) => object>([
  [
    "async",
    (): Mailbox<number> => {
      const inbox = new Mailbox<number>();
      void idle(inbox);
      return inbox;
    },
  ],
  [
    "async-als",
    (index): Mailbox<number> => {
      const inbox = new Mailbox<number>();
      storage.run(index, () => void idle(inbox));
      return inbox;
    },
  ],
  [
    "object",
    (index) => ({ inbox: new Mailbox<number>(), behavior: (step: number) => step + index }),
  ],
]);

type Measure = (first: number, second: number) => Promise<object>;

const settle = async (): Promise<NodeJS.MemoryUsage> => {
  await new Promise((resolve) => setImmediate(resolve));
  collect();
  collect();
  return process.memoryUsage();
};

const spawnModes = [...actorKinds].map(([kind, create]): [string, Measure] => [
  `spawn-${kind}`,
  async (count) => {
    const before = await settle();
    const start = performance.now();
    const actors = Array.from({ length: count }, (_, index) => create(index));
    const elapsed = (performance.now() - start) * nanosecondsPerMillisecond;
    const after = await settle();
    return {
      kind,
      count: actors.length,
      spawn_ns_total: elapsed,
      spawn_ns_per_actor: elapsed / count,
      heap_used_bytes_per_actor: (after.heapUsed - before.heapUsed) / count,
      rss_bytes_per_actor: (after.rss - before.rss) / count,
    };
  },
]);

const server = new Mailbox<Request>();

void (async (): Promise<void> => {
  for await (const request of server) request.replyTo.send(request.remaining);
})();

const exchange = async (rounds: number, latencies?: Float64Array): Promise<number> => {
  const inbox = new Mailbox<number>();
  const start = performance.now();
  let sent = start;
  server.send({ replyTo: inbox, remaining: rounds - 1 });
  for await (const remaining of inbox) {
    if (latencies !== undefined) latencies[remaining] = performance.now() - sent;
    if (remaining === 0) break;
    if (latencies !== undefined) sent = performance.now();
    server.send({ replyTo: inbox, remaining: remaining - 1 });
  }
  return (performance.now() - start) * nanosecondsPerMillisecond;
};

const relay = async (
  inbox: Mailbox<number>,
  next: Mailbox<number>,
  finish: () => void,
): Promise<void> => {
  for await (const remaining of inbox) {
    if (remaining === 0) return finish();
    next.send(remaining - 1);
  }
};

const modes = new Map<string, Measure>([
  ...spawnModes,
  [
    "round-trip",
    async (rounds, warmup) => {
      await exchange(warmup);
      const untimed = await exchange(rounds);
      const latencies = new Float64Array(rounds);
      const timed = await exchange(rounds, latencies);
      const timerOnly = new Float64Array(rounds).map(() => {
        const start = performance.now();
        return performance.now() - start;
      });
      return {
        round_trips: rounds,
        warmup_round_trips: warmup,
        untimed_total_ns: untimed,
        untimed_mean_ns: untimed / rounds,
        round_trips_per_s: rounds / (untimed / 1e9),
        timed_total_ns: timed,
        latency_ns: percentiles(latencies),
        timer_only_ns: percentiles(timerOnly),
      };
    },
  ],
  [
    "ring",
    async (size, laps) => {
      const finished = Promise.withResolvers<void>();
      const start = performance.now();
      const first = new Mailbox<number>();
      const last = Array.from({ length: size - 1 }).reduce<Mailbox<number>>((next) => {
        const inbox = new Mailbox<number>();
        void relay(inbox, next, finished.resolve);
        return inbox;
      }, first);
      void relay(first, last, finished.resolve);
      const ready = performance.now();
      const hops = size * laps;
      first.send(hops);
      await finished.promise;
      const runNs = (performance.now() - ready) * nanosecondsPerMillisecond;
      return {
        size,
        laps,
        hops,
        setup_ns: (ready - start) * nanosecondsPerMillisecond,
        run_ns: runNs,
        ns_per_hop: runNs / hops,
        hops_per_s: hops / (runNs / 1e9),
      };
    },
  ],
]);

const [mode = "", firstArgument = "0", secondArgument = "0"] = process.argv.slice(2);
const measure = modes.get(mode);
if (measure === undefined) throw new Error(`Unknown mode ${mode}.`);
const result = await measure(Number(firstArgument), Number(secondArgument));
console.log(JSON.stringify({ mode, ...result, vm: environment }));
