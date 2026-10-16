import { spawn, type Ref } from "bouy";

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

export function collect(items: string[]): Set<string> {
  const seen = new Set<string>();
  for (const item of items) {
    seen.add(item);
  }
  return seen;
}

export const store = spawn(Store);
