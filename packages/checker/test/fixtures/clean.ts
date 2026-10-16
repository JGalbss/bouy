import { child, spawn, supervise, tree, type Ref } from "bouy";

const LIMITS = { max: 3 };
const NAMES: ReadonlyArray<string> = ["ada", "lin"];

interface Note {
  readonly title: string;
  readonly tags: ReadonlyArray<string>;
  readonly created?: Date;
}

interface Loaded {
  readonly id: bigint;
  readonly size: number;
  readonly at: Date;
}

interface Names extends ReadonlyArray<string> {}

interface Registry extends ReadonlyMap<string, number> {}

type Status = "idle" | "busy";

class Peer {
  ping(): string {
    return "pong";
  }
}

class Plain {
  run(callback: () => void): void {
    callback();
  }
}

class Library {
  readonly #notes: Array<Note> = [];
  #count = 0;

  add(note: Note): number {
    this.#notes.push(note);
    this.#count += 1;
    return this.#count;
  }

  find(title: string, limit?: number): Note | undefined {
    return this.#notes.slice(0, limit ?? LIMITS.max).find((note) => note.title === title);
  }

  async load(id: bigint, raw: Uint8Array, at: Date): Promise<Loaded> {
    await Promise.resolve();
    return { id, size: raw.length, at };
  }

  index(
    entries: ReadonlyMap<string, ReadonlySet<number>>,
    pair: readonly [string, number],
    flags: Readonly<Record<string, boolean>>,
  ): Status {
    return entries.size + pair[1] + Object.keys(flags).length > 0 ? "busy" : "idle";
  }

  wrapped(
    counts: Readonly<Map<string, number>>,
    seen: Readonly<Set<string>>,
    at: Readonly<Date>,
  ): number {
    return counts.size + seen.size + at.getTime();
  }

  derived(names: Names, registry: Registry): number {
    return names.length + registry.size;
  }

  narrow<T extends string>(value: NonNullable<T>): T {
    return value;
  }

  link(peer: Ref<Peer>, peers: ReadonlyArray<Ref<Peer>>): Ref<Peer> | undefined {
    return peers[0] ?? peer;
  }

  label(value: `note-${string}`, extra: null, count: 1 | 2): string {
    return `${value}${extra ?? ""}${count}`;
  }

  echo<T extends string>(value: T): T {
    return value;
  }

  names(): ReadonlyArray<string> {
    return NAMES;
  }

  async *titles(prefix: string): AsyncGenerator<string> {
    for (const note of this.#notes) yield `${prefix}${note.title}`;
  }

  async flush(): Promise<void> {
    await this.persist();
    void this.persist();
    const pending = this.persist();
    await pending;
    await Promise.all([this.persist(), this.persist()]);
    return this.persist();
  }

  async [Symbol.asyncDispose](): Promise<void> {
    await this.persist();
  }

  private persist(): Promise<void> {
    return Promise.resolve();
  }

  private notify(callback: () => void): void {
    callback();
  }

  #secret(callback: () => void): void {
    callback();
  }

  static create(callback: () => void): Library {
    callback();
    return new Library();
  }
}

new Plain().run(() => undefined);
spawn(Library);
supervise({
  strategy: "one-for-one",
  children: {
    peer: child(Peer),
    nested: tree({ strategy: "one-for-all", children: { library: child(Library) } }),
  },
});
