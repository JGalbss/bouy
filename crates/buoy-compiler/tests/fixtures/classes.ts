import { spawn } from "buoy";
import { Data } from "effect";

export class Account {
  #balance = 0;
  readonly owner: string;
  history: number[] = [];

  constructor(owner: string) {
    this.owner = owner;
  }

  deposit(amount: number): number {
    this.#balance += amount;
    this.#log(amount);
    return this.#balance;
  }

  #log(amount: number): void {
    this.history.push(amount);
  }

  balance(): number {
    return this.#balance;
  }

  labels(): string[] {
    return this.history.map((amount) => this.#label(amount));
  }

  #label(amount: number): string {
    return `${this.owner}:${amount}`;
  }
}

export class Overdrawn extends Error {
  needed: number;
  constructor(needed: number) {
    super(`needs ${needed} more`);
    this.name = "Overdrawn";
    this.needed = needed;
  }
}

export class Plain extends Error {}

export class Missing extends Data.TaggedError("Missing")<{ readonly id: string }> {}

export function open(owner: string) {
  const ref = spawn(Account, { args: [owner] });
  ref.add(1);
  return [ref, new Overdrawn(5), new Plain("x"), new Missing({ id: "1" })];
}
