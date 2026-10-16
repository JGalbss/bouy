import type { Fiber, Scheduler } from "effect";

const SLICE_MS = 4;
const IDLE_GAP_MS = 1;
const REDUCTIONS_PER_CHECK = 1024;
const TASKS_PER_CLOCK_CHECK = 64;
const settled = Promise.resolve();

class SharedDispatcher implements Scheduler.SchedulerDispatcher {
  #tasks: Array<() => void> = [];
  #pending: "none" | "microtask" | "macrotask" = "none";
  #sliceStartedAt = performance.now();
  #lastActiveAt = 0;
  #tasksSinceClockCheck = 0;

  get isSliceSpent(): boolean {
    return performance.now() - this.#sliceStartedAt >= SLICE_MS;
  }

  scheduleTask(task: () => void): void {
    this.#tasks.push(task);
    if (this.#pending !== "none") return;
    this.#tasksSinceClockCheck += 1;
    if (this.#tasksSinceClockCheck >= TASKS_PER_CLOCK_CHECK && this.isSliceSpent) {
      this.#tasksSinceClockCheck = 0;
      this.#pending = "macrotask";
      setImmediate(this.#afterYield);
      return;
    }
    this.#pending = "microtask";
    void settled.then(this.#afterMicrotask);
  }

  flush(): void {
    while (this.#tasks.length > 0) this.#runTasks();
  }

  restartSlice(): void {
    this.#sliceStartedAt = performance.now();
  }

  readonly #afterMicrotask = (): void => {
    this.#pending = "none";
    this.#runTasks();
  };

  readonly #afterYield = (): void => {
    this.#pending = "none";
    this.restartSlice();
    this.#runTasks();
  };

  #runTasks(): void {
    const tasks = this.#tasks;
    this.#tasks = [];
    if (this.#tasksSinceClockCheck === 0) {
      const startedAt = performance.now();
      if (startedAt - this.#lastActiveAt > IDLE_GAP_MS) this.#sliceStartedAt = startedAt;
      this.#lastActiveAt = startedAt;
    }
    for (const task of tasks) task();
  }
}

export class FairScheduler implements Scheduler.Scheduler {
  readonly executionMode = "async";
  readonly #dispatcher = new SharedDispatcher();
  #reductions = REDUCTIONS_PER_CHECK;

  shouldYield(fiber: Fiber.Fiber<unknown, unknown>): boolean {
    return fiber.currentOpCount >= fiber.cache.maxOpsBeforeYield;
  }

  makeDispatcher(): Scheduler.SchedulerDispatcher {
    return this.#dispatcher;
  }

  spendReduction(): boolean {
    this.#reductions -= 1;
    if (this.#reductions > 0) return false;
    this.#reductions = REDUCTIONS_PER_CHECK;
    return this.#dispatcher.isSliceSpent;
  }

  yieldToEventLoop(): Promise<void> {
    return new Promise((resolve) => {
      setImmediate(() => {
        this.#dispatcher.restartSlice();
        resolve();
      });
    });
  }
}

export const fairScheduler = new FairScheduler();
