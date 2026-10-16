import { ManagedRuntime } from "effect";
import type { ActorExit, ActorSnapshot } from "./runtime/Actor.ts";
import {
  ActorSystem,
  type ChildSpec,
  type SpawnOptions,
  type TreeRefs,
  type TreeSpec,
} from "./runtime/ActorSystem.ts";
import { isRefTo, isSelfRef, type ActorClass, type Cast, type Ref } from "./runtime/Blueprint.ts";
import type { MailboxOptions } from "./runtime/Mailbox.ts";
import { castViewFor } from "./runtime/Messaging.ts";
import { actorKey, Reference } from "./runtime/Sendable.ts";
import type { RestartPolicy, RestartType, Strategy } from "./runtime/Supervisor.ts";
import { currentTurn } from "./runtime/Turn.ts";

export {
  ActorClassInvalid,
  ActorFailed,
  ActorStopped,
  CallCycle,
  MailboxFull,
  MessageDropped,
  NotSendable,
} from "./runtime/errors.ts";
import type { Sendable } from "./runtime/Sendable.ts";
export type { OverflowPolicy } from "./runtime/Mailbox.ts";
export { signal, withSignal } from "./runtime/Turn.ts";
export type {
  Sendable,
  ActorExit,
  ActorSnapshot,
  Cast,
  MailboxOptions,
  Ref,
  RestartPolicy,
  RestartType,
  Strategy,
};

type Arguments<C extends ActorClass> = ConstructorParameters<C>;

export type Options<C extends ActorClass> = Omit<SpawnOptions, "args"> &
  (Partial<Arguments<C>> extends Arguments<C>
    ? { readonly args?: Arguments<C> }
    : { readonly args: Arguments<C> });

type OptionsArgument<C extends ActorClass> =
  Partial<Arguments<C>> extends Arguments<C> ? [options?: Options<C>] : [options: Options<C>];

export interface Child<C extends ActorClass> extends ChildSpec {
  readonly actorClass: C;
}

export interface Tree<Children extends Readonly<Record<string, Member>>> extends TreeSpec {
  readonly children: Children;
}

type Member = Child<ActorClass> | Tree<Readonly<Record<string, Member>>>;

export type Supervision<Children> = {
  readonly [K in keyof Children]: Children[K] extends Child<infer C>
    ? Ref<InstanceType<C>>
    : Children[K] extends Tree<infer Nested>
      ? Supervision<Nested>
      : never;
};

export interface TreeOptions<Children> {
  readonly strategy: Strategy;
  readonly restart?: RestartType;
  readonly maxRestarts?: number;
  readonly withinMs?: number;
  readonly children: Children;
}

class DefaultSystem {
  #runtime: ManagedRuntime.ManagedRuntime<ActorSystem, never> | undefined;

  get runtime(): ManagedRuntime.ManagedRuntime<ActorSystem, never> {
    this.#runtime ??= ManagedRuntime.make(ActorSystem.layer);
    return this.#runtime;
  }

  async dispose(): Promise<void> {
    const runtime = this.#runtime;
    this.#runtime = undefined;
    await runtime?.dispose();
  }
}

const defaultSystem = new DefaultSystem();

const system = (): ManagedRuntime.ManagedRuntime<ActorSystem, never> => defaultSystem.runtime;

const spawnOptions = <C extends ActorClass>(options: Options<C> | undefined): SpawnOptions => ({
  ...options,
  args: options?.args ?? [],
});

const isSupervision = <Children extends Readonly<Record<string, Member>>>(
  refs: TreeRefs,
  children: Children,
): refs is Supervision<Children> =>
  Object.entries(children).every(([name, member]) => {
    const entry = refs[name];
    if (entry instanceof Reference)
      return member.kind === "actor" && isRefTo(entry, member.actorClass);
    return entry !== undefined && member.kind === "tree" && isSupervision(entry, member.children);
  });

export const spawn = <C extends ActorClass>(
  actorClass: C,
  ...[options]: OptionsArgument<C>
): Ref<InstanceType<C>> => {
  const ref = system().runSync(
    ActorSystem.use((actors) => actors.spawn(actorClass, spawnOptions(options))),
  );
  if (isRefTo(ref, actorClass)) return ref;
  throw new TypeError(`spawn returned a ref to ${ref[actorKey].label}, not to ${actorClass.name}`);
};

export const child = <C extends ActorClass>(
  actorClass: C,
  ...[options]: OptionsArgument<C>
): Child<C> => ({
  kind: "actor",
  actorClass,
  options: spawnOptions(options),
});

export const tree = <Children extends Readonly<Record<string, Member>>>(
  options: TreeOptions<Children>,
): Tree<Children> => ({ kind: "tree", ...options });

export const supervise = <Children extends Readonly<Record<string, Member>>>(
  options: TreeOptions<Children>,
): Supervision<Children> => {
  const refs = system().runSync(ActorSystem.use((actors) => actors.supervise(tree(options))));
  if (isSupervision(refs, options.children)) return refs;
  throw new TypeError("supervise returned refs that do not match its children");
};

export const cast = <T>(ref: Ref<T>): Cast<T> => castViewFor(ref);

export const self = <T extends object>(instance: T): Ref<T> => {
  const ref = currentTurn()?.actor.ref;
  if (ref !== undefined && isSelfRef(ref, instance)) return ref;
  throw new Error(
    `self() needs the current actor instance inside its own turn, not ${instance.constructor.name}`,
  );
};

export const stop = (ref: Reference): Promise<void> =>
  system().runPromise(ActorSystem.use((actors) => actors.stop(ref)));

export const monitor = (ref: Reference): Promise<ActorExit> => ref[actorKey].exited;

export const inspect = (): ReadonlyArray<ActorSnapshot> =>
  system().runSync(ActorSystem.use((actors) => actors.inspect));

export const shutdown = (): Promise<void> => defaultSystem.dispose();
