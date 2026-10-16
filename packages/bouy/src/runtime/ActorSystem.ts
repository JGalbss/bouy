import { Context, Deferred, Effect, Fiber, Layer, Scheduler, type Scope } from "effect";
import { Actor, type ActorSnapshot } from "./Actor.ts";
import type { ActorClass } from "./Blueprint.ts";
import { ActorClassInvalid, ActorFailed, keepOrWrap, NotSendable, type Crash } from "./errors.ts";
import { fairScheduler } from "./FairScheduler.ts";
import { Mailbox, type MailboxOptions } from "./Mailbox.ts";
import { blueprintFor } from "./Messaging.ts";
import { actorKey, copyArguments, copyError, type Reference } from "./Sendable.ts";
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

export interface SpawnOptions {
  readonly name?: string;
  readonly args?: ReadonlyArray<unknown>;
  readonly mailbox?: MailboxOptions;
  readonly restart?: RestartPolicy;
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

interface Registration {
  readonly actor: Actor;
  readonly stop: Effect.Effect<void>;
}

interface Built {
  readonly tree: Tree;
  readonly refs: TreeRefs;
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
      const scope = yield* Effect.scope;
      const registry = new Map<string, Registration>();
      const sequence = { next: 0 };

      yield* Effect.acquireRelease(
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

      const ownerScope = (): Scope.Scope => currentTurn()?.incarnation.scope ?? scope;

      const register = (actor: Actor, stop: Effect.Effect<void>): void => {
        registry.set(actor.id, { actor, stop });
        void actor.exited.then(() => registry.delete(actor.id));
      };

      const nextId = (): string => {
        sequence.next += 1;
        return String(sequence.next);
      };

      const create = Effect.fnUntraced(function* (actorClass: ActorClass, options: SpawnOptions) {
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
        const id = nextId();
        const name = options.name ?? blueprint.name;
        const mailbox = yield* Mailbox.make(options.mailbox ?? {}, `${name}#${id}`);
        const construct = (values: ReadonlyArray<unknown>): object =>
          Reflect.construct(actorClass, values);
        return new Actor({ id, name, blueprint, construct, args, mailbox });
      });

      const build = (label: string, spec: TreeSpec): Effect.Effect<Built, SpawnError> =>
        Effect.gen(function* () {
          const children: Array<TreeChild> = [];
          const refs: Record<string, Reference | TreeRefs> = {};
          const actors: Array<Actor> = [];
          for (const [name, member] of Object.entries(spec.children)) {
            if (member.kind === "tree") {
              const nested = yield* build(`${label}/${name}`, member);
              children.push({ node: nested.tree, restart: member.restart ?? "permanent" });
              refs[name] = nested.refs;
              continue;
            }
            const actor = yield* create(member.actorClass, { name, ...member.options });
            children.push({ node: actor, restart: member.options.restart?.restart ?? "permanent" });
            refs[name] = actor.ref;
            actors.push(actor);
          }
          const tree = new Tree({ label, strategy: spec.strategy, children, policy: spec });
          for (const actor of actors) register(actor, tree.stopChild(actor));
          return { tree, refs };
        });

      const spawn = Effect.fn("ActorSystem.spawn")(
        function* (actorClass: ActorClass, options: SpawnOptions) {
          const actor = yield* create(actorClass, options);
          const lifetime = yield* superviseAlone(actor, options.restart ?? {}).pipe(
            Effect.forkIn(ownerScope(), { startImmediately: true }),
          );
          register(actor, Fiber.interrupt(lifetime));
          yield* awaitStart(actor);
          return actor.ref;
        },
        Effect.provideService(Scheduler.Scheduler, fairScheduler),
      );

      const supervise = Effect.fn("ActorSystem.supervise")(
        function* (spec: TreeSpec) {
          const { tree, refs } = yield* build(`supervisor#${nextId()}`, spec);
          yield* tree.incarnate().pipe(
            Effect.catch((crash) =>
              tree.terminate({ kind: "failed", cause: copyError(crash.cause) }),
            ),
            Effect.onInterrupt(() => tree.terminate({ kind: "stopped" })),
            Effect.forkIn(ownerScope(), { startImmediately: true }),
          );
          yield* awaitStart(tree);
          return refs;
        },
        Effect.provideService(Scheduler.Scheduler, fairScheduler),
      );

      const stop = Effect.fn("ActorSystem.stop")(function* (ref: Reference) {
        yield* registry.get(ref[actorKey].id)?.stop ?? Effect.void;
      });

      const inspect = Effect.sync(() =>
        [...registry.values()].map(({ actor }) => actor.snapshot()),
      );

      return ActorSystem.of({ spawn, supervise, stop, inspect });
    }),
  );
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
