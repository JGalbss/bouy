import type { LanguageModelUsage } from "ai";
import type { JobQueue } from "./queue.ts";

export interface Counter {
  inc(by?: number): number;
  reset(): void;
  readonly value: number;
}

export function createCounter(initial = 0): Counter {
  let value = initial;
  return {
    inc(by = 1) {
      value += by;
      return value;
    },
    reset() {
      value = initial;
    },
    get value() {
      return value;
    },
  };
}

export interface UsageTotals {
  calls: number;
  inputTokens: number;
  outputTokens: number;
  totalTokens: number;
}

/** Adds the usage of one model call to `totals`. */
export function addUsage(totals: UsageTotals, usage: LanguageModelUsage): void {
  totals.calls += 1;
  totals.inputTokens += usage.inputTokens ?? 0;
  totals.outputTokens += usage.outputTokens ?? 0;
  totals.totalTokens += usage.totalTokens ?? 0;
}

export class Metrics {
  readonly #counters = new Map<string, Counter>();
  readonly usage: UsageTotals = { calls: 0, inputTokens: 0, outputTokens: 0, totalTokens: 0 };

  counter(name: string): Counter {
    let counter = this.#counters.get(name);
    if (!counter) {
      counter = createCounter();
      this.#counters.set(name, counter);
    }
    return counter;
  }

  /** Counts the events of `queue`, and returns a function that stops counting. */
  watch(queue: JobQueue): () => void {
    const queued = this.counter("jobs.queued");
    const done = this.counter("jobs.done");
    const failed = this.counter("jobs.failed");
    const onQueued = () => queued.inc();
    const onDone = () => done.inc();
    const onFailed = () => failed.inc();
    queue.on("queued", onQueued).on("done", onDone).on("failed", onFailed);
    return () => {
      queue.off("queued", onQueued).off("done", onDone).off("failed", onFailed);
    };
  }

  snapshot(): Record<string, number> {
    const snapshot: Record<string, number> = {};
    this.#counters.forEach((counter, name) => {
      snapshot[name] = counter.value;
    });
    return snapshot;
  }
}
