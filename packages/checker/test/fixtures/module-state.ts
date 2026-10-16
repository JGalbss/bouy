import { spawn } from "bouy";
import { registry } from "./registry.ts";

let counter = 0;
var legacy = "legacy";
const queue: Array<string> = [];
queue.push("boot");
const settings = { verbose: false };
settings.verbose = true;
const cache = new Map<string, number>();
const LIMITS = { max: 3 };
const names = new Set(["ada"]);
const sessions = new Map([["first", { messages: ["hello"] }]]);
let ticks = 0;

const tick = (): number => {
  ticks += 1;
  return ticks;
};

function advance(): number {
  return tick();
}

class Counter {
  #local = 0;

  increment(): number {
    counter += 1;
    return counter;
  }

  label(): string {
    return legacy;
  }

  next(): string | undefined {
    return queue.shift();
  }

  verbose(): boolean {
    return settings.verbose;
  }

  record(key: string): void {
    cache.set(key, 1);
  }

  shared(): number {
    return registry.length;
  }

  append(message: string): void {
    sessions.get("first")?.messages.push(message);
  }

  step(): number {
    return advance();
  }

  local(): number {
    this.#local += LIMITS.max;
    return names.size + this.#local;
  }

  typed(): typeof counter {
    return this.#local;
  }
}

spawn(Counter);
