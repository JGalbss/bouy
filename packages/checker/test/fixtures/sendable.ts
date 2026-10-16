import { spawn } from "bouy";

interface Task {
  readonly id: string;
  run(): void;
}

interface RetryOptions {
  readonly retry: { readonly onRetry: () => void };
}

class Item {
  readonly name = "item";
}

interface Items extends ReadonlyArray<Item> {}

type Nest<T> = { readonly next: Nest<readonly [T]> };

class Worker {
  enqueue(task: Task): void {}

  subscribe(listener: (event: string) => void): void {}

  store(items: ReadonlyArray<Item>): void {}

  accept(input: unknown): void {}

  tag(key: symbol): void {}

  wait(signal: Promise<string>): void {}

  fail(error: Error): void {}

  configure(options: RetryOptions): void {}

  lookup(table: Map<string, Item>): void {}

  hold<T>(value: T): void {}

  take(value: {}): void {}

  shelve(items: Items): void {}

  descend(nest: Nest<string>): void {}

  claim({ id, run }: Task): void {}

  ["schedule"](job: () => void): void {}

  callback(): () => void {
    return () => undefined;
  }

  async item(): Promise<Item> {
    return new Item();
  }

  async *items(): AsyncGenerator<Item> {
    yield new Item();
  }
}

spawn(Worker);
