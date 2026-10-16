import { Context, Deferred, Effect, Fiber, Layer, Scheduler, type Scope } from "effect";
import { ThreadBody, type ThreadOptions } from "../thread/ThreadBody.ts";
import { Actor, type ActorSnapshot, type Embody } from "./Actor.ts";
import type { ActorClass, Blueprint } from "./Blueprint.ts";
import { LocalBody } from "./Body.ts";
import { ActorClassInvalid, ActorFailed, keepOrWrap, NotSendable, type Crash } from "./errors.ts";
import { fairScheduler } from "./FairScheduler.ts";
import { Mailbox, type MailboxOptions } from "./Mailbox.ts";
import { blueprintFor } from "./Messaging.ts";
import { actorKey, copyArguments, copyError, type Reference, type Sendable } from "./Sendable.ts";
import {
  superviseAlone,
  Tree,
  type RestartPolicy,
  type RestartType,
  type Strategy,
  type Supervisable,
  type TreeChild,
} from "./Supervisor.ts";
import { currentTurn } from "./Turn.ts";

export type Isolation = "shared" | "thread";

export interface SpawnOptions {
  readonly name?: string;
  readonly args?: ReadonlyArray<unknown>;
  readonly mailbox?: MailboxOptions;
  readonly restart?: RestartPolicy;
  readonly isolation?: Isolation;
  readonly thread?: ThreadOptions;
}

export interface ChildSpec {
  readonly kind: "actor";
  readonly actorClass: ActorClass;
  readonly options: SpawnOptions;
}

export interface TreeSpec {
  readonly kind: "tree";
  readonly strategy: Strategy;
  readonly restart?: RestartType;
  readonly maxRestarts?: number;
  readonly withinMs?: number;
  readonly children: { readonly [name: string]: ChildSpec | TreeSpec };
}

export interface TreeRefs {
  readonly [name: string]: Reference | TreeRefs;
}

export type SpawnError = ActorFailed | ActorClassInvalid | NotSendable;

interface Built {
  readonly tree: Tree;
  readonly refs: TreeRefs;
}

const awaitStart = (node: Supervisable): Effect.Effect<void, ActorFailed> =>
  Deferred.await(node.started).pipe(
    Effect.mapError(
      (crash: Crash) =>
        new ActorFailed({ actor: node.label, method: "start", cause: copyError(crash.cause) }),
    ),
  );

const attributeFault = (cause: unknown): void => {
  const turn = currentTurn();
  if (turn === undefined) {
    process.exitCode = 1;
    console.error("bouy: an error escaped outside any actor turn", cause);
    return;
  }
  turn.incarnation.crash(cause);
};

const containFaults = Effect.acquireRelease(
  Effect.sync(() => {
    process.on("uncaughtException", attributeFault);
    process.on("unhandledRejection", attributeFault);
  }),
  () =>
    Effect.sync(() => {
      process.off("uncaughtException", attributeFault);
      process.off("unhandledRejection", attributeFault);
    }),
);

class Actors {
  readonly #scope: Scope.Scope;
  readonly #registry = new Map<
    string,
    { readonly actor: Actor; readonly stop: Effect.Effect<void> }
  >();
  #sequence = 0;

  constructor(scope: Scope.Scope) {
    this.#scope = scope;
  }

  get snapshots(): ReadonlyArray<ActorSnapshot> {
    return [...this.#registry.values()].map(({ actor }) => actor.snapshot());
  }

  stopping(ref: Reference): Effect.Effect<void> {
    return this.#registry.get(ref[actorKey].id)?.stop ?? Effect.void;
  }

  spawn(actorClass: ActorClass, options: SpawnOptions): Effect.Effect<Reference, SpawnError> {
    return Effect.gen({ self: this }, function* () {
      const actor = yield* this.#create(actorClass, options);
      const lifetime = yield* superviseAlone(actor, options.restart ?? {}).pipe(
        Effect.forkIn(this.#ownerScope(), { startImmediately: true }),
      );
      this.#register(actor, Fiber.interrupt(lifetime));
      if (options.isolation !== "thread") yield* awaitStart(actor);
      return actor.ref;
    });
  }

  supervise(spec: TreeSpec): Effect.Effect<TreeRefs, SpawnError> {
    return Effect.gen({ self: this }, function* () {
      const { tree, refs } = yield* this.#build(`supervisor#${this.#nextId()}`, spec);
      yield* tree.incarnate().pipe(
        Effect.catch((crash) => tree.terminate({ kind: "failed", cause: copyError(crash.cause) })),
        Effect.onInterrupt(() => tree.terminate({ kind: "stopped" })),
        Effect.forkIn(this.#ownerScope(), { startImmediately: true }),
      );
      yield* awaitStart(tree);
      return refs;
    });
  }

  #ownerScope(): Scope.Scope {
    return currentTurn()?.incarnation.scope ?? this.#scope;
  }

  #nextId(): string {
    this.#sequence += 1;
    return String(this.#sequence);
  }

  #register(actor: Actor, stop: Effect.Effect<void>): void {
    this.#registry.set(actor.id, { actor, stop });
    void actor.exited.then(() => this.#registry.delete(actor.id));
  }

  #create(actorClass: ActorClass, options: SpawnOptions): Effect.Effect<Actor, SpawnError> {
    return Effect.gen({ self: this }, function* () {
      const blueprint = yield* Effect.try({
        try: () => blueprintFor(actorClass),
        catch: (cause) =>
          keepOrWrap(
            cause,
            ActorClassInvalid,
            () => new ActorClassInvalid({ actorClass: actorClass.name, reason: String(cause) }),
          ),
      });
      const args = yield* Effect.try({
        try: () => copyArguments(options.args ?? []),
        catch: (cause) =>
          keepOrWrap(cause, NotSendable, () => new NotSendable({ value: String(cause) })),
      });
      const embody = yield* this.#embodiment(actorClass, blueprint, options);
      const id = this.#nextId();
      const name = options.name ?? blueprint.name;
      const mailbox = yield* Mailbox.make(options.mailbox ?? {}, `${name}#${id}`);
      return new Actor({ id, name, blueprint, embody, args, mailbox });
    });
  }

  #embodiment(
    actorClass: ActorClass,
    blueprint: Blueprint,
    options: SpawnOptions,
  ): Effect.Effect<Embody, ActorClassInvalid> {
    if (options.isolation !== "thread") {
      return Effect.succeed<Embody>(
        (values) => new LocalBody(Reflect.construct(actorClass, values), blueprint),
      );
    }
    const location = blueprint.location;
    if (location === undefined) {
      return Effect.fail(
        new ActorClassInvalid({
          actorClass: blueprint.name,
          reason:
            "thread isolation needs the class's module and export name; export the class and run it under bouy",
        }),
      );
    }
    const thread: Embody = (values: ReadonlyArray<Sendable>, incarnation) =>
      ThreadBody.start({
        location,
        args: values,
        options: options.thread ?? {},
        onFault: (cause) => incarnation.crash(cause),
      });
    return Effect.succeed(thread);
  }

  #build(label: string, spec: TreeSpec): Effect.Effect<Built, SpawnError> {
    return Effect.gen({ self: this }, function* () {
      const children: Array<TreeChild> = [];
      const refs: Record<string, Reference | TreeRefs> = {};
      const actors: Array<Actor> = [];
      for (const [name, member] of Object.entries(spec.children)) {
        if (member.kind === "tree") {
          const nested = yield* this.#build(`${label}/${name}`, member);
          children.push({ node: nested.tree, restart: member.restart ?? "permanent" });
          refs[name] = nested.refs;
          continue;
        }
        const actor = yield* this.#create(member.actorClass, { name, ...member.options });
        children.push({ node: actor, restart: member.options.restart?.restart ?? "permanent" });
        refs[name] = actor.ref;
        actors.push(actor);
      }
      const tree = new Tree({ label, strategy: spec.strategy, children, policy: spec });
      for (const actor of actors) this.#register(actor, tree.stopChild(actor));
      return { tree, refs };
    });
  }
}

export class ActorSystem extends Context.Service<
  ActorSystem,
  {
    spawn(actorClass: ActorClass, options: SpawnOptions): Effect.Effect<Reference, SpawnError>;
    supervise(spec: TreeSpec): Effect.Effect<TreeRefs, SpawnError>;
    stop(ref: Reference): Effect.Effect<void>;
    readonly inspect: Effect.Effect<ReadonlyArray<ActorSnapshot>>;
  }
>()("bouy/runtime/ActorSystem") {
  static readonly layer = Layer.effect(
    ActorSystem,
    Effect.gen(function* () {
      yield* containFaults;
      const actors = new Actors(yield* Effect.scope);
      return ActorSystem.of({
        spawn: (actorClass: ActorClass, options: SpawnOptions) =>
          actors
            .spawn(actorClass, options)
            .pipe(Effect.provideService(Scheduler.Scheduler, fairScheduler)),
        supervise: (spec: TreeSpec) =>
          actors.supervise(spec).pipe(Effect.provideService(Scheduler.Scheduler, fairScheduler)),
        stop: Effect.fn("ActorSystem.stop")((ref: Reference) => actors.stopping(ref)),
        inspect: Effect.sync(() => actors.snapshots),
      });
    }),
  );
}
