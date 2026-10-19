// Actor state through `finally`, method values, `this[name](...)`, fluent methods,
// `Object.assign(this, ...)`, Map entries of fields, private fields, and an overloaded
// constructor.
import { child, spawn, supervise } from "buoy";

class Counter {
  #n = 0;
  #runs = 0;

  #next(): number {
    return ++this.#n;
  }

  count(limit: number): string {
    try {
      while (this.#next() < limit) {
        if (this.#n > 100) return "too many";
      }
    } finally {
      this.#runs++;
    }
    return `${this.#n} after ${this.#runs} runs`;
  }
}

class Handler {
  total = 0;

  constructor() {
    this.onEvent = this.onEvent.bind(this);
  }

  onEvent(x: number): number {
    return x + 1;
  }

  greet(name: string): string {
    return `hi ${name}`;
  }

  add(n: number): number {
    this.total += n;
    return this.total;
  }

  run(op: string): string {
    const mapped = [1, 2].map(this.onEvent);
    const greeting = this.greet?.("bo");
    const changed = this[op](5);
    return `${mapped.join(",")} ${typeof this.greet} ${greeting} ${changed} ${this.total}`;
  }
}

class Builder {
  parts: string[] = [];
  tag = "none";

  constructor(init: { tag?: string }) {
    Object.assign(this, init);
  }

  add(part: string): this {
    this.parts.push(part);
    return this;
  }

  build(): string {
    this.add("a").add("b");
    return `${this.tag} ${this.parts.join(",")}`;
  }
}

class Topics {
  #subs = new Map<string, number[]>([["news", []]]);
  owner = "ann";
  #pin = "1234";

  subscribe(topic: string, id: number): number {
    this.#subs.get(topic)!.push(id);
    this.#subs.get("missing")?.push(id);
    return this.#subs.get(topic)!.length;
  }

  snapshot(): string {
    return `${JSON.stringify(this)} ${Object.keys(this).join(",")} ${"#pin" in this} ${this.#pin.length}`;
  }
}

class Label {
  text = "unset";

  constructor(n: number);
  constructor(s: string);
  constructor(v: number | string) {
    this.text = `label:${v}`;
  }

  get(): string {
    return this.text;
  }
}

class HttpError extends Error {
  constructor(
    public status: number,
    message: string,
  ) {
    super(message);
  }
}

class Tally {
  #total = 0;

  add(n: number): number {
    this.#total += n;
    return this.#total;
  }
}

const counter = spawn(Counter, {});
console.log(await counter.count(3));
console.log(await counter.count(3));
console.log(await spawn(Handler, {}).run("add"));
console.log(await spawn(Builder, { args: [{ tag: "dark" }] }).build());
const topics = spawn(Topics, {});
console.log(await topics.subscribe("news", 7), await topics.subscribe("news", 8));
console.log(await topics.snapshot());
console.log(await spawn(Label, { args: [5] }).get());
const failure = new HttpError(404, "missing");
console.log(failure.message, failure.status);
const { tally } = supervise({ children: { tally: child(Tally) } });
console.log((await Promise.all([1, 2].map((n) => tally.add(n)))).join(","));
