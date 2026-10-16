import { Worker, type WorkerOptions } from "node:worker_threads";
import { Match, Schema } from "effect";
import type { Location, Outcome } from "../runtime/Blueprint.ts";
import type { Body } from "../runtime/Body.ts";
import { copyError, type Sendable } from "../runtime/Sendable.ts";
import { errorFrom, FromWorker } from "./protocol.ts";

export interface ThreadOptions {
  readonly stallMs?: number;
  readonly maxHeapMb?: number;
}

export interface ThreadLaunch {
  readonly location: Location;
  readonly args: ReadonlyArray<Sendable>;
  readonly options: ThreadOptions;
  readonly onFault: (cause: Error) => void;
}

export const DEFAULT_STALL_MS = 5_000;

const HOST = new URL("./host.ts", import.meta.url);
const decode = Schema.decodeUnknownSync(FromWorker);

export class ThreadBody implements Body {
  readonly #worker: Worker;
  readonly #pending = new Map<number, PromiseWithResolvers<Sendable>>();
  readonly #ready = Promise.withResolvers<ThreadBody>();
  readonly #stallMs: number;
  readonly #onFault: (cause: Error) => void;
  readonly #watchdog: NodeJS.Timeout;
  #nextId = 0;
  #lastPong = performance.now();
  #faulted = false;
  #isReady = false;

  constructor(launch: ThreadLaunch) {
    this.#stallMs = launch.options.stallMs ?? DEFAULT_STALL_MS;
    this.#onFault = launch.onFault;
    const options: WorkerOptions = {
      workerData: {
        module: launch.location.module,
        exportName: launch.location.exportName,
        args: launch.args,
      },
    };
    if (launch.options.maxHeapMb !== undefined) {
      options.resourceLimits = { maxOldGenerationSizeMb: launch.options.maxHeapMb };
    }
    this.#worker = new Worker(HOST, options);
    this.#worker.on("message", (raw) => this.#receive(decode(raw)));
    this.#worker.on("error", (cause) => this.#fault(copyError(cause)));
    this.#worker.on("exit", (code) =>
      this.#fault(new Error(`the actor thread exited with code ${code}`)),
    );
    this.#watchdog = setInterval(() => this.#watch(), Math.max(10, this.#stallMs / 4));
    this.#watchdog.unref();
  }

  static start(launch: ThreadLaunch): Promise<ThreadBody> {
    return new ThreadBody(launch).#ready.promise;
  }

  invoke(method: string, args: ReadonlyArray<Sendable>): Outcome {
    this.#nextId += 1;
    const reply = Promise.withResolvers<Sendable>();
    this.#pending.set(this.#nextId, reply);
    this.#worker.postMessage({ _tag: "Call", id: this.#nextId, method, args }, []);
    return reply.promise;
  }

  owns(): boolean {
    return false;
  }

  async dispose(): Promise<void> {
    this.#faulted = true;
    clearInterval(this.#watchdog);
    await this.#worker.terminate();
  }

  #receive(message: Schema.Schema.Type<typeof FromWorker>): void {
    Match.valueTags(message, {
      Ready: () => {
        this.#isReady = true;
        this.#lastPong = performance.now();
        this.#ready.resolve(this);
      },
      StartFailed: (report) => this.#ready.reject(errorFrom(report)),
      Pong: () => {
        this.#lastPong = performance.now();
      },
      Reply: ({ id, value }) => {
        this.#pending.get(id)?.resolve(value);
        this.#pending.delete(id);
      },
      Failed: ({ id, ...report }) => {
        this.#pending.get(id)?.reject(errorFrom(report));
        this.#pending.delete(id);
      },
    });
  }

  #watch(): void {
    if (!this.#isReady) return;
    if (performance.now() - this.#lastPong > this.#stallMs) {
      this.#fault(
        new Error(`the actor thread stopped answering for more than ${this.#stallMs} ms`),
      );
      void this.#worker.terminate();
      return;
    }
    this.#worker.postMessage({ _tag: "Ping", at: performance.now() }, []);
  }

  #fault(cause: Error): void {
    if (this.#faulted) return;
    this.#faulted = true;
    clearInterval(this.#watchdog);
    this.#ready.reject(cause);
    for (const reply of this.#pending.values()) reply.reject(cause);
    this.#pending.clear();
    this.#onFault(cause);
  }
}
