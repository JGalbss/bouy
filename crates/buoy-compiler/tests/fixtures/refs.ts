import { spawn, type Ref } from "buoy";

export class Store {
  #items: string[] = [];

  add(item: string): number {
    this.#items.push(item);
    return this.#items.length;
  }
}

export class Router {
  #items: Ref<Store>;
  #backup?: Ref<Store> | undefined;

  constructor(store: Ref<Store>) {
    this.#items = store;
  }

  route(items: string[]): Promise<number[]> {
    return Promise.all(items.map((item) => this.#items.add(item)));
  }

  connect(backup: Ref<Store>): void {
    this.#backup = backup;
  }
}

export function fill(store: Ref<Store>, items: string[]): Promise<number[]> {
  const target: Ref<Store> = store;
  return Promise.all(items.map((item) => target.add(item)));
}

// The receiver is the first parameter and the argument is a name, so the calls go out
// together (`buoy_task:map_call/3`).
export function broadcast(stores: Ref<Store>[], item: string): Promise<number[]> {
  return Promise.all(stores.map((store) => store.add(item)));
}

// A template literal may run code, so each call runs in a worker (`buoy_task:map/3`).
export function shout(stores: Ref<Store>[], item: string): Promise<number[]> {
  return Promise.all(stores.map((store) => store.add(`${item}!`)));
}

export function collect(items: string[]): Set<string> {
  const seen = new Set<string>();
  for (const item of items) {
    seen.add(item);
  }
  return seen;
}

export const store = spawn(Store);
