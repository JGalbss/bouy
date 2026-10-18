import { Data, Effect } from "effect";
import { inspect, spawn } from "buoy";

class InsufficientFunds extends Data.TaggedError("InsufficientFunds")<{
  readonly balance: number;
}> {}

// Each method returns an Effect, and the actor runs it in the same turn (contract section 8).
class Wallet {
  #balance = 100;
  #refusals = 0;

  withdraw(amount: number) {
    if (amount > this.#balance) {
      this.#refusals += 1;
      return Effect.fail(new InsufficientFunds({ balance: this.#balance }));
    }
    this.#balance -= amount;
    return Effect.succeed(this.#balance);
  }

  report() {
    const balance = this.#balance;
    const refusals = this.#refusals;
    return Effect.gen(function* () {
      yield* Effect.sleep("10 millis");
      return `balance ${balance}, refusals ${refusals}`;
    });
  }

  corrupt() {
    return Effect.die(new Error("corrupt ledger"));
  }
}

const wallet = spawn(Wallet, { name: "main" });
console.log(`withdrew 30, left ${await wallet.withdraw(30)}`);
try {
  await wallet.withdraw(500);
} catch (error) {
  console.log(`typed failure at the caller: ${error._tag}, balance ${error.balance}`);
}
console.log(`the state stays: ${await wallet.report()}`);
try {
  await wallet.corrupt();
} catch (error) {
  console.log(`a defect crashes the actor: ${error._tag}`);
}
console.log(`after the restart: ${await wallet.report()}`);
const [entry] = inspect();
console.log(`${entry.name}: ${entry.status}, restarts ${entry.restarts}`);
