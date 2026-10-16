import { inspect, spawn } from "bouy";

class Account {
  #balance = 0;

  deposit(amount: number): number {
    if (amount < 0) {
      throw new Error("negative deposit");
    }
    this.#balance += amount;
    return this.#balance;
  }
}

async function main(): Promise<void> {
  const alice = spawn(Account, { name: "alice" });
  const bob = spawn(Account, { name: "bob" });
  await alice.deposit(50);
  await bob.deposit(10);
  try {
    await alice.deposit(-1);
  } catch (error) {
    console.log(error.message);
    console.log(error._tag);
  }
  console.log(`bob still answers: ${await bob.deposit(5)}`);
  console.log(`alice restarted with a fresh balance: ${await alice.deposit(1)}`);
  for (const actor of inspect()) {
    console.log(`${actor.name}: ${actor.status}, restarts ${actor.restarts}`);
  }
}

await main();
