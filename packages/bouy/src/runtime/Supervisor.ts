import {
  Data,
  Deferred,
  Duration,
  Effect,
  Fiber,
  Option,
  Queue,
  Schedule,
  type Scope,
} from "effect";
import type { ActorExit } from "./Actor.ts";
import type { Crash } from "./errors.ts";
import { copyError } from "./Sendable.ts";

export type RestartType = "permanent" | "transient" | "temporary";

export type Strategy = "one-for-one" | "one-for-all" | "rest-for-one";

export interface Backoff {
  readonly initialMs: number;
  readonly maxMs: number;
}

export interface RestartPolicy {
  readonly restart?: RestartType;
  readonly maxRestarts?: number;
  readonly withinMs?: number;
  readonly backoff?: Backoff;
}

export const DEFAULT_MAX_RESTARTS = 3;
export const DEFAULT_WITHIN_MS = 5_000;

export class Intensity {
  readonly #maxRestarts: number;
  readonly #withinMs: number;
  #restarts: ReadonlyArray<number> = [];

  constructor(policy: RestartPolicy) {
    this.#maxRestarts = policy.maxRestarts ?? DEFAULT_MAX_RESTARTS;
    this.#withinMs = policy.withinMs ?? DEFAULT_WITHIN_MS;
  }

  admits(now: number): boolean {
    const recent = this.#restarts.filter((at) => now - at < this.#withinMs);
    this.#restarts = recent;
    if (recent.length >= this.#maxRestarts) return false;
    this.#restarts = [...recent, now];
    return true;
  }
}

export interface Supervisable {
  readonly label: string;
  readonly started: Deferred.Deferred<void, Crash>;
  readonly hasStarted: boolean;
  incarnate(): Effect.Effect<never, Crash>;
  restarting(crash: Crash): void;
  terminate(exit: ActorExit): Effect.Effect<void>;
}

export const superviseAlone = (child: Supervisable, policy: RestartPolicy): Effect.Effect<void> => {
  const intensity = new Intensity(policy);
  const restarts = policy.restart !== "temporary";
  const delays = Option.fromUndefinedOr(policy.backoff).pipe(
    Option.match({
      onNone: (): Schedule.Schedule<unknown, Crash> => Schedule.forever,
      onSome: (backoff) =>
        Schedule.exponential(Duration.millis(backoff.initialMs)).pipe(
          Schedule.modifyDelay(({ duration }) =>
            Effect.succeed(Duration.min(duration, Duration.millis(backoff.maxMs))),
          ),
        ),
    }),
  );
  return child.incarnate().pipe(
    Effect.tapError((crash) => Effect.sync(() => child.restarting(crash))),
    Effect.retry({
      schedule: delays,
      while: () => restarts && child.hasStarted && intensity.admits(Date.now()),
    }),
    Effect.catch((crash) => child.terminate({ kind: "failed", cause: copyError(crash.cause) })),
    Effect.onInterrupt(() => child.terminate({ kind: "stopped" })),
  );
};

export interface TreeChild {
  readonly node: Supervisable;
  readonly restart: RestartType;
}

type Signal = Data.TaggedEnum<{
  Crashed: { readonly index: number; readonly crash: Crash };
  StopRequested: { readonly index: number; readonly done: Deferred.Deferred<void> };
}>;

const Signal = Data.taggedEnum<Signal>();

const AFFECTED: Record<Strategy, (crashed: number, count: number) => ReadonlyArray<number>> = {
  "one-for-one": (crashed) => [crashed],
  "one-for-all": (_crashed, count) => Array.from({ length: count }, (_value, index) => index),
  "rest-for-one": (crashed, count) =>
    Array.from({ length: count - crashed }, (_value, offset) => crashed + offset),
};

export interface TreeSettings {
  readonly label: string;
  readonly strategy: Strategy;
  readonly children: ReadonlyArray<TreeChild>;
  readonly policy: RestartPolicy;
}

interface Running {
  readonly scope: Scope.Scope;
  readonly fibers: Map<number, Fiber.Fiber<void>>;
}

export class Tree implements Supervisable {
  readonly label: string;
  readonly started = Deferred.makeUnsafe<void, Crash>();
  readonly children: ReadonlyArray<TreeChild>;
  readonly #strategy: Strategy;
  readonly #intensity: Intensity;
  readonly #signals = Effect.runSync(Queue.unbounded<Signal>());
  readonly #removed = new Set<number>();
  #hasStarted = false;

  constructor(settings: TreeSettings) {
    this.label = settings.label;
    this.#strategy = settings.strategy;
    this.#intensity = new Intensity(settings.policy);
    this.children = settings.children;
  }

  get hasStarted(): boolean {
    return this.#hasStarted;
  }

  stopChild(node: Supervisable): Effect.Effect<void> {
    const index = this.children.findIndex((child) => child.node === node);
    return Effect.gen({ self: this }, function* () {
      const done = yield* Deferred.make<void>();
      yield* Queue.offer(this.#signals, Signal.StopRequested({ index, done }));
      yield* Deferred.await(done);
    });
  }

  incarnate(): Effect.Effect<never, Crash> {
    return Effect.scoped(
      Effect.gen({ self: this }, function* () {
        const running: Running = { scope: yield* Effect.scope, fibers: new Map() };
        for (const index of this.children.keys())
          running.fibers.set(index, yield* this.#start(index, running.scope));
        yield* Effect.forEach(this.children, (child) => Deferred.await(child.node.started), {
          discard: true,
        });
        this.#hasStarted = true;
        Deferred.doneUnsafe(this.started, Effect.void);
        while (true) {
          const signal = yield* Queue.take(this.#signals);
          yield* Signal.$match(signal, {
            Crashed: ({ index, crash }) => this.#recover(index, crash, running),
            StopRequested: ({ index, done }) => this.#remove(index, done, running),
          });
        }
      }),
    ).pipe(Effect.tapError((crash) => Deferred.fail(this.started, crash)));
  }

  restarting(crash: Crash): void {
    for (const child of this.children) child.node.restarting(crash);
  }

  terminate(exit: ActorExit): Effect.Effect<void> {
    return Effect.forEach(this.children, (child) => child.node.terminate(exit), { discard: true });
  }

  #start(index: number, scope: Scope.Scope): Effect.Effect<Fiber.Fiber<void>> {
    const child = this.children[index];
    if (child === undefined)
      return Effect.die(new RangeError(`${this.label} has no child ${index}`));
    return child.node.incarnate().pipe(
      Effect.catch((crash) => Queue.offer(this.#signals, Signal.Crashed({ index, crash }))),
      Effect.asVoid,
      Effect.forkIn(scope, { startImmediately: true }),
    );
  }

  #recover(index: number, crash: Crash, running: Running): Effect.Effect<void, Crash> {
    this.children[index]?.node.restarting(crash);
    if (!this.#intensity.admits(Date.now())) return Effect.fail(crash);
    const affected = AFFECTED[this.#strategy](index, this.children.length).filter(
      (target) => !this.#removed.has(target),
    );
    return Effect.gen({ self: this }, function* () {
      for (const target of affected) {
        const sibling = running.fibers.get(target);
        if (target !== index && sibling !== undefined) yield* Fiber.interrupt(sibling);
      }
      for (const target of affected) {
        const child = this.children[target];
        if (child === undefined) continue;
        if (target === index && child.restart === "temporary") {
          this.#removed.add(target);
          yield* child.node.terminate({ kind: "stopped" });
          continue;
        }
        running.fibers.set(target, yield* this.#start(target, running.scope));
      }
    });
  }

  #remove(index: number, done: Deferred.Deferred<void>, running: Running): Effect.Effect<void> {
    this.#removed.add(index);
    const fiber = running.fibers.get(index);
    const child = this.children[index];
    return Effect.gen(function* () {
      if (fiber !== undefined) yield* Fiber.interrupt(fiber);
      if (child !== undefined) yield* child.node.terminate({ kind: "stopped" });
      yield* Deferred.succeed(done, undefined);
    });
  }
}
