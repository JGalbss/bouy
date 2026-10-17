import { EventEmitter } from "node:events";
import { QueueClosedError } from "./errors.ts";
import { defer, withTimeout, type Deferred } from "./util/async.ts";

export enum Priority {
  Low,
  Normal,
  High,
}

export enum JobStatus {
  Queued = "queued",
  Running = "running",
  Done = "done",
  Failed = "failed",
}

const PRIORITY_ORDER = [Priority.High, Priority.Normal, Priority.Low];

export class Job<T = unknown> {
  static #nextId = 1;

  readonly id: string;
  status = JobStatus.Queued;
  attempts = 0;
  result: T | undefined;
  error: unknown;
  readonly enqueuedAt: number;
  startedAt: number | undefined;
  finishedAt: number | undefined;

  constructor(
    readonly name: string,
    readonly priority: Priority,
    readonly run: () => Promise<T>,
    now: number,
  ) {
    this.id = `job-${Job.#nextId++}`;
    this.enqueuedAt = now;
  }

  get durationMs(): number | undefined {
    if (this.startedAt === undefined || this.finishedAt === undefined) return undefined;
    return this.finishedAt - this.startedAt;
  }

  get isSettled(): boolean {
    return this.status === JobStatus.Done || this.status === JobStatus.Failed;
  }

  toJSON(): Record<string, unknown> {
    return {
      id: this.id,
      name: this.name,
      priority: Priority[this.priority],
      status: this.status,
      attempts: this.attempts,
    };
  }
}

type QueueEvents = {
  queued: [job: Job];
  started: [job: Job];
  done: [job: Job];
  failed: [job: Job, error: unknown];
  idle: [];
};

export interface JobQueueOptions {
  concurrency: number;
  timeoutMs: number;
  now?: () => number;
}

/**
 * An in-process job queue with priorities and a concurrency limit. Jobs added in the same
 * tick are started in priority order, highest first.
 */
export class JobQueue extends EventEmitter<QueueEvents> {
  readonly concurrency: number;
  readonly #timeoutMs: number;
  readonly #now: () => number;
  readonly #pending = new Map<Priority, Job[]>(PRIORITY_ORDER.map((priority) => [priority, []]));
  readonly #all: Job[] = [];
  readonly #waiters = new Map<string, Deferred<any>>();
  readonly #startOrder: string[] = [];
  #running = 0;
  #closed = false;
  #pumpScheduled = false;

  constructor(options: JobQueueOptions) {
    super();
    if (options.concurrency < 1) throw new RangeError("concurrency must be at least 1");
    this.concurrency = options.concurrency;
    this.#timeoutMs = options.timeoutMs;
    this.#now = options.now ?? Date.now;
  }

  get running(): number {
    return this.#running;
  }

  get pending(): number {
    let count = 0;
    for (const bucket of this.#pending.values()) count += bucket.length;
    return count;
  }

  get jobs(): readonly Job[] {
    return this.#all;
  }

  get startOrder(): readonly string[] {
    return this.#startOrder;
  }

  add<T>(name: string, run: () => Promise<T>, priority: Priority = Priority.Normal): Promise<T> {
    if (this.#closed) return Promise.reject(new QueueClosedError(name));
    const job = new Job<T>(name, priority, run, this.#now());
    const done = defer<T>();
    this.#all.push(job);
    this.#pending.get(priority)!.push(job);
    this.#waiters.set(job.id, done);
    this.emit("queued", job);
    this.#schedulePump();
    return done.promise;
  }

  onIdle(): Promise<void> {
    if (this.#running === 0 && this.pending === 0) return Promise.resolve();
    return new Promise((resolve) => this.once("idle", resolve));
  }

  async close(): Promise<void> {
    this.#closed = true;
    await this.onIdle();
    this.removeAllListeners();
  }

  // Deferred to the next tick so that a burst of adds is ordered by priority, not by arrival.
  #schedulePump(): void {
    if (this.#pumpScheduled) return;
    this.#pumpScheduled = true;
    process.nextTick(() => {
      this.#pumpScheduled = false;
      this.#pump();
    });
  }

  #pump(): void {
    scheduling: for (const priority of PRIORITY_ORDER) {
      const bucket = this.#pending.get(priority)!;
      while (bucket.length > 0) {
        if (this.#running >= this.concurrency) break scheduling;
        this.#start(bucket.shift()!);
      }
    }
    if (this.#running === 0 && this.pending === 0) this.emit("idle");
  }

  #start(job: Job): void {
    this.#running++;
    this.#startOrder.push(job.id);
    job.status = JobStatus.Running;
    job.startedAt = this.#now();
    job.attempts++;
    this.emit("started", job);

    withTimeout(job.run(), this.#timeoutMs, job.name)
      .then((result) => {
        job.status = JobStatus.Done;
        job.result = result;
        this.#settle(job)?.resolve(result);
        this.emit("done", job);
      })
      .catch((error: unknown) => {
        job.status = JobStatus.Failed;
        job.error = error;
        this.#settle(job)?.reject(error);
        this.emit("failed", job, error);
      })
      .finally(() => {
        job.finishedAt = this.#now();
        this.#running--;
        this.#pump();
      });
  }

  #settle(job: Job): Deferred<unknown> | undefined {
    const waiter = this.#waiters.get(job.id);
    this.#waiters.delete(job.id);
    return waiter;
  }
}
