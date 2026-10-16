import { AsyncLocalStorage } from "node:async_hooks";
import type { Actor, Incarnation } from "./Actor.ts";

export interface Origin {
  readonly chain: symbol;
  readonly signal: AbortSignal | undefined;
}

export class TurnContext {
  readonly actor: Actor;
  readonly incarnation: Incarnation;
  readonly origin: Origin;
  #signal: AbortSignal | undefined;

  constructor(actor: Actor, incarnation: Incarnation, origin: Origin) {
    this.actor = actor;
    this.incarnation = incarnation;
    this.origin = origin;
  }

  get signal(): AbortSignal {
    this.#signal ??= combine(this.origin.signal, this.incarnation.signal);
    return this.#signal;
  }

  get isCancelled(): boolean {
    return this.origin.signal?.aborted === true || this.incarnation.signal.aborted;
  }
}

interface Ambient {
  readonly turn: TurnContext | undefined;
  readonly signal: AbortSignal | undefined;
}

const storage = new AsyncLocalStorage<Ambient>();
const unaborted = new AbortController().signal;

const combine = (first: AbortSignal | undefined, second: AbortSignal): AbortSignal => {
  if (first === undefined) return second;
  return AbortSignal.any([first, second]);
};

export const runTurn = <A>(turn: TurnContext, body: () => A): A =>
  storage.run({ turn, signal: undefined }, body);

export const currentTurn = (): TurnContext | undefined => storage.getStore()?.turn;

export const currentOrigin = (): Origin => {
  const ambient = storage.getStore();
  const turn = ambient?.turn;
  return {
    chain: turn?.origin.chain ?? Symbol("bouy.chain"),
    signal: ambient?.signal ?? turn?.signal,
  };
};

export const signal = (): AbortSignal => {
  const ambient = storage.getStore();
  return ambient?.signal ?? ambient?.turn?.signal ?? unaborted;
};

export const withSignal = <A>(cancellation: AbortSignal | undefined, body: () => A): A => {
  if (cancellation === undefined) return body();
  const ambient = storage.getStore();
  const inherited = ambient?.signal ?? ambient?.turn?.signal;
  return storage.run({ turn: ambient?.turn, signal: combine(inherited, cancellation) }, body);
};
