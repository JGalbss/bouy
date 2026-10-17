// An actor's method mutates this and awaits a timer; another call waits its turn.
import { spawn } from "bouy";

class Account {
  balance = 0;
  log: string[] = [];

  async deposit(amount: number, ms: number): Promise<number> {
    this.log.push(`start ${amount}`);
    const before = this.balance;
    await new Promise((resolve) => setTimeout(resolve, ms));
    this.balance = before + amount;
    this.log.push(`end ${amount}`);
    return this.balance;
  }

  history(): string[] {
    return this.log;
  }
}

async function main(): Promise<void> {
  const account = spawn(Account);
  const first = account.deposit(10, 30);
  const second = account.deposit(5, 1);
  console.log(await first, await second);
  console.log(await account.history());
}

await main();
