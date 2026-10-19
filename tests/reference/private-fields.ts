// Private fields and methods are per instance and invisible to keys and JSON.
class Account {
  #balance = 0;
  #history: number[] = [];
  owner: string;
  constructor(owner: string) {
    this.owner = owner;
  }
  #record(amount: number): void {
    this.#history.push(amount);
  }
  deposit(amount: number): this {
    this.#balance += amount;
    this.#record(amount);
    return this;
  }
  get balance(): number {
    return this.#balance;
  }
  history(): number[] {
    return [...this.#history];
  }
}

const a = new Account("ann");
const b = new Account("bob");
a.deposit(10).deposit(5);
b.deposit(1);
console.log(a.balance, b.balance, a.history(), b.history());
console.log(Object.keys(a), JSON.stringify(a));
const h = a.history();
h.push(1000);
console.log(a.history().length);

// An optional call of a private field ends the chain when the field holds null.
class Matcher {
  #match: ((text: string) => boolean) | null;
  constructor(match: ((text: string) => boolean) | null) {
    this.#match = match;
  }
  test(text: string): boolean | undefined {
    return this.#match?.(text);
  }
}
console.log(new Matcher(null).test("a"), new Matcher((text) => text === "a").test("a"));
