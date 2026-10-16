// The Node baseline for a Bouy actor: an object with a mailbox queue that runs one
// message at a time on the event loop and answers each call with a promise. A send never
// runs the receiver inline, because the mailbox drains in a microtask. A method that
// throws rejects its caller and logs one line to stderr, and the actor builds a fresh
// state, as a Bouy supervisor restarts a crashed actor. The queue is unbounded.

type Job = {
  method: string;
  args: unknown[];
  resolve?: (value: unknown) => void;
  reject?: (error: unknown) => void;
};

type Methods = Record<string, ((...args: unknown[]) => unknown) | undefined>;

export class Actor {
  #make: () => object;
  #state: object;
  #jobs: (Job | undefined)[] = [];
  #head = 0;
  #draining = false;

  constructor(make: () => object) {
    this.#make = make;
    this.#state = make();
  }

  call(method: string, ...args: unknown[]): Promise<unknown> {
    return new Promise((resolve, reject) => this.#post({ method, args, resolve, reject }));
  }

  cast(method: string, ...args: unknown[]): void {
    this.#post({ method, args });
  }

  #post(job: Job): void {
    this.#jobs.push(job);
    if (this.#draining) return;
    this.#draining = true;
    queueMicrotask(() => void this.#drain());
  }

  // A synchronous method runs without an await, so a queue of them drains in one task.
  async #drain(): Promise<void> {
    while (this.#head < this.#jobs.length) {
      const job = this.#jobs[this.#head];
      this.#jobs[this.#head] = undefined;
      this.#head += 1;
      if (job === undefined) continue;
      // Dynamic dispatch by method name: the one place where the state is untyped.
      const state = this.#state as Methods;
      try {
        const method = state[job.method];
        if (method === undefined) throw new TypeError(`${job.method} is not a function`);
        const result = method.apply(state, job.args);
        job.resolve?.(result instanceof Promise ? await result : result);
      } catch (error) {
        console.error(`node: ${state.constructor?.name} crashed: ${String(error)}`);
        this.#state = this.#make();
        job.reject?.(error);
      }
    }
    this.#jobs = [];
    this.#head = 0;
    this.#draining = false;
  }
}

// The nearest-rank percentile of sorted samples.
export function percentile(sorted: ArrayLike<number>, fraction: number): number {
  return sorted[Math.max(0, Math.ceil(fraction * sorted.length) - 1)] ?? 0;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}
