import type { Actor } from "./Actor.ts";
import { Predicate } from "effect";
import { ActorClassInvalid } from "./errors.ts";
import { actorKey, Reference, type Sendable } from "./Sendable.ts";

export type ActorClass = abstract new (...args: never[]) => object;

export type Behavior = ActorClass extends abstract new (...args: never[]) => infer B ? B : never;

export type MethodKind = "call" | "stream";

export interface Location {
  readonly module: string;
  readonly exportName: string;
}

export type MethodName<T> = {
  [K in keyof T]-?: K extends string ? (T[K] extends (...args: never) => void ? K : never) : never;
}[keyof T];

export type Remote<F> = F extends (...args: infer A) => infer R
  ? [R] extends [AsyncIterable<infer Y>]
    ? (...args: A) => AsyncIterable<Y>
    : (...args: A) => Promise<Awaited<R>>
  : never;

type Delivery<F> = F extends (...args: infer A) => void ? (...args: A) => Promise<boolean> : never;

export type RemoteMethods<T> = { readonly [K in MethodName<T>]: Remote<T[K]> };

export type Ref<T> = Reference & RemoteMethods<T>;

export type Arguments<F> = F extends (...args: infer A) => void ? A : never;

export type Cast<T> = { readonly [K in MethodName<T>]: Delivery<T[K]> };

export type Outcome = Sendable | Promise<Sendable> | AsyncIterable<Sendable>;

export type Method = (this: Behavior, ...args: ReadonlyArray<Sendable>) => Outcome;

export interface MethodEntry {
  readonly kind: MethodKind;
  readonly invoke: Method;
}

type Send<A> = (ref: Reference, method: string, args: ReadonlyArray<unknown>) => A;

type CastView = Readonly<Record<string, (...args: ReadonlyArray<unknown>) => Promise<boolean>>>;

type Members = Readonly<Record<string, (...args: ReadonlyArray<never>) => void>>;

export interface Dispatch {
  readonly call: Send<Promise<Sendable>>;
  readonly stream: Send<AsyncIterable<Sendable>>;
  readonly cast: Send<Promise<boolean>>;
}

const AsyncGeneratorFunction = Object.getPrototypeOf(async function* () {}).constructor;

const KIND_BY_GENERATOR = new Map<boolean, MethodKind>([
  [true, "stream"],
  [false, "call"],
]);

export const isMethod = (value: unknown): value is Method => Predicate.isFunction(value);

export const isActorClass = (value: unknown): value is ActorClass =>
  Predicate.isFunction(value) && Predicate.isObject(value.prototype);

export class Blueprint {
  readonly actorClass: ActorClass;
  readonly name: string;
  readonly methods: ReadonlyMap<string, MethodEntry>;
  readonly disposer: Method | undefined;
  readonly #refPrototype: Reference;
  readonly #castViews = new WeakMap<Reference, CastView>();
  #location: Location | undefined;

  constructor(actorClass: ActorClass, dispatch: Dispatch) {
    this.actorClass = actorClass;
    this.name = actorClass.name || "Actor";
    this.methods = Blueprint.#methodTable(actorClass);
    this.disposer = Blueprint.#disposerFor(actorClass);
    this.#refPrototype = Object.create(Reference.prototype);
    for (const [name, { kind }] of this.methods) {
      const send = dispatch[kind];
      Object.defineProperty(this.#refPrototype, name, {
        value: function (this: Reference, ...args: ReadonlyArray<unknown>) {
          return send(this, name, args);
        },
      });
    }
  }

  static #methodTable(actorClass: ActorClass): ReadonlyMap<string, MethodEntry> {
    const methods = new Map<string, MethodEntry>();
    for (
      let prototype = actorClass.prototype;
      prototype !== null && prototype !== Object.prototype;
      prototype = Object.getPrototypeOf(prototype)
    ) {
      for (const [name, descriptor] of Object.entries(
        Object.getOwnPropertyDescriptors(prototype),
      )) {
        const invoke: unknown = descriptor.value;
        if (name === "constructor" || methods.has(name) || !isMethod(invoke)) continue;
        const kind = KIND_BY_GENERATOR.get(invoke instanceof AsyncGeneratorFunction) ?? "call";
        methods.set(name, { kind, invoke });
      }
    }
    if (methods.has("then")) {
      throw new ActorClassInvalid({
        actorClass: actorClass.name,
        reason: "it defines then(), so every ref to it would look like a promise",
      });
    }
    return methods;
  }

  static #disposerFor(actorClass: ActorClass): Method | undefined {
    for (
      let prototype = actorClass.prototype;
      prototype !== null && prototype !== Object.prototype;
      prototype = Object.getPrototypeOf(prototype)
    ) {
      const cleanup = [Symbol.asyncDispose, Symbol.dispose]
        .map((key) => Object.getOwnPropertyDescriptor(prototype, key)?.value)
        .find(isMethod);
      if (cleanup !== undefined) return cleanup;
    }
    return undefined;
  }

  get location(): Location | undefined {
    return this.#location;
  }

  locate(location: Location): void {
    this.#location ??= location;
  }

  refFor(actor: Actor): Reference {
    return Object.freeze(Object.create(this.#refPrototype, { [actorKey]: { value: actor } }));
  }

  routerFor<T>(pick: () => Ref<T>, dispatch: Dispatch): RemoteMethods<T> {
    const router: Record<
      string,
      (...args: ReadonlyArray<unknown>) => Promise<Sendable> | AsyncIterable<Sendable>
    > = Object.create(null);
    for (const [name, { kind }] of this.methods) {
      router[name] = (...args: ReadonlyArray<unknown>) => dispatch[kind](pick(), name, args);
    }
    if (this.#isRouterFor(router, pick)) return Object.freeze(router);
    throw new TypeError(`${this.name} has no router for this pool`);
  }

  castFor<T>(ref: Ref<T>, dispatch: Dispatch): Cast<T> {
    const view = this.#castViews.get(ref) ?? this.#buildCastView(ref, dispatch);
    this.#castViews.set(ref, view);
    if (this.#isCastViewFor(view, ref)) return view;
    throw new TypeError(`${this.name} has no cast view for this ref`);
  }

  #buildCastView(ref: Reference, dispatch: Dispatch): CastView {
    const view: Record<string, (...args: ReadonlyArray<unknown>) => Promise<boolean>> =
      Object.create(null);
    for (const name of this.methods.keys()) {
      view[name] = (...args: ReadonlyArray<unknown>) => dispatch.cast(ref, name, args);
    }
    return Object.freeze(view);
  }

  #isCastViewFor<T>(view: CastView, ref: Ref<T>): view is CastView & Cast<T> {
    return ref[actorKey].blueprint === this && this.#coversEveryMethod(view);
  }

  #isRouterFor<T>(router: Members, pick: () => Ref<T>): router is Members & RemoteMethods<T> {
    return pick()[actorKey].blueprint === this && this.#coversEveryMethod(router);
  }

  #coversEveryMethod(candidate: Members): boolean {
    return [...this.methods.keys()].every((name) => name in candidate);
  }
}

export const isRefTo = <C extends ActorClass>(
  ref: Reference,
  actorClass: C,
): ref is Ref<InstanceType<C>> => ref[actorKey].blueprint.actorClass === actorClass;

export const isSelfRef = <T extends object>(ref: Reference, behavior: T): ref is Ref<T> =>
  ref[actorKey].incarnation?.owns(behavior) === true;
