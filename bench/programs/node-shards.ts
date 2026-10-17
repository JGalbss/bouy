// Agents on worker threads, the protection of the runaway-loop and memory-leak baselines.
// One event loop cannot stop a loop that never yields, and one heap fails as a whole, so
// the agents run in a pool of worker threads, a shard of agents in each one. A worker
// hosts its agents as mailbox actors from node-actor.ts. The main thread calls an agent
// with a timeout. When a worker ends, by terminate() or by the heap limit of its
// resourceLimits, its pending calls fail and the pool starts the shard again.
import { type ResourceLimits, Worker, parentPort, workerData } from "node:worker_threads";
import { Actor } from "./node-actor.ts";

type Request = { id: number; agent: number; method: string; args: unknown[] };
type Reply = { id: number; value?: unknown; error?: string };
type Pending = {
  resolve: (value: unknown) => void;
  reject: (error: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
  worker: Worker;
};

const READY = -1;

export type ShardOptions = {
  // The module that calls serveShard() in a worker thread.
  url: URL;
  shards: number;
  agents: number;
  resourceLimits?: ResourceLimits;
};

export class Shards {
  // The shards that ended on their own, such as by the heap limit, and started again.
  restarts = 0;
  // Called when a worker ends on its own, before its shard starts again.
  onExit?: (shard: number) => void;
  #options: ShardOptions;
  #workers: Worker[] = [];
  #ready: Promise<void>[] = [];
  #replaced = new Set<Worker>();
  #pending = new Map<number, Pending>();
  #next = 0;
  #closing = false;

  constructor(options: ShardOptions) {
    this.#options = options;
    for (let shard = 0; shard < options.shards; shard++) this.#start(shard);
  }

  shardOf(agent: number): number {
    return agent % this.#options.shards;
  }

  ready(): Promise<unknown> {
    return Promise.all(this.#ready);
  }

  call(agent: number, method: string, timeoutMs: number, ...args: unknown[]): Promise<unknown> {
    const worker = this.#workers[this.shardOf(agent)];
    if (worker === undefined) return Promise.reject(new Error(`no shard for agent ${agent}`));
    const id = this.#next++;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new Error(`agent ${agent} did not answer within ${timeoutMs} ms`));
      }, timeoutMs);
      this.#pending.set(id, { resolve, reject, timer, worker });
      const request: Request = { id, agent, method, args };
      worker.postMessage(request);
    });
  }

  // Starts a new worker for the shard, terminates the old one, and resolves with the
  // time when the old one has ended. The new worker takes the calls from then on.
  async restart(shard: number): Promise<number> {
    const old = this.#workers[shard];
    if (old === undefined) throw new Error(`no shard ${shard}`);
    this.#replaced.add(old);
    this.#start(shard);
    await old.terminate();
    const ended = performance.now();
    await this.#ready[shard];
    return ended;
  }

  async close(): Promise<void> {
    this.#closing = true;
    await Promise.all(this.#workers.map((worker) => worker.terminate()));
  }

  #start(shard: number): void {
    const { url, shards, agents, resourceLimits } = this.#options;
    const worker = new Worker(url, {
      workerData: { shard, shards, agents },
      ...(resourceLimits === undefined ? {} : { resourceLimits }),
    });
    this.#workers[shard] = worker;
    this.#ready[shard] = new Promise((resolve) => {
      worker.on("message", (reply: Reply) => {
        if (reply.id === READY) resolve();
        else this.#settle(reply);
      });
    });
    // ERR_WORKER_OUT_OF_MEMORY and other faults end the worker; "exit" handles them.
    worker.on("error", () => {});
    worker.on("exit", () => this.#ended(shard, worker));
  }

  #settle(reply: Reply): void {
    const pending = this.#pending.get(reply.id);
    if (pending === undefined) return;
    this.#pending.delete(reply.id);
    clearTimeout(pending.timer);
    if (reply.error === undefined) pending.resolve(reply.value);
    else pending.reject(new Error(reply.error));
  }

  #ended(shard: number, worker: Worker): void {
    for (const [id, pending] of this.#pending) {
      if (pending.worker !== worker) continue;
      this.#pending.delete(id);
      clearTimeout(pending.timer);
      pending.reject(new Error(`shard ${shard} ended`));
    }
    if (this.#closing || this.#replaced.delete(worker)) return;
    this.restarts++;
    this.onExit?.(shard);
    this.#start(shard);
  }
}

// The worker side: hosts the agents of this shard and answers the calls of the main
// thread. `make` builds the state of one agent.
export function serveShard(make: (agent: number) => object): void {
  const port = parentPort;
  if (port === null) throw new Error("serveShard() runs in a worker thread");
  const { shard, shards, agents } = workerData;
  const actors = new Map<number, Actor>();
  for (let agent = shard; agent < agents; agent += shards) {
    actors.set(agent, new Actor(() => make(agent)));
  }
  port.on("message", (request: Request) => {
    const actor = actors.get(request.agent);
    if (actor === undefined) return;
    actor.call(request.method, ...request.args).then(
      (value) => port.postMessage({ id: request.id, value }),
      (error) => port.postMessage({ id: request.id, error: String(error) }),
    );
  });
  port.postMessage({ id: READY });
}
