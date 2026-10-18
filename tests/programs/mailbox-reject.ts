import { cast, sleep, spawn } from "buoy";

class Slow {
  work(ms: number): void {
    sleep(ms);
  }

  ping(): string {
    return "pong";
  }
}

async function main(): Promise<void> {
  const slow = spawn(Slow, { name: "slow", mailbox: { capacity: 2, overflow: "reject" } });
  let accepted = 0;
  for (let i = 0; i < 10; i++) {
    try {
      cast(slow).work(200);
      accepted++;
    } catch (error) {
      console.log(`${error._tag}: ${error.message}`);
      break;
    }
  }
  // The actor may take the first cast before the next arrives, so 2 or 3 fit.
  console.log(`accepted before the mailbox filled: ${accepted === 2 || accepted === 3}`);
  let reply = "";
  while (reply === "") {
    try {
      reply = await slow.ping();
    } catch (error) {
      await sleep(20);
    }
  }
  console.log(`after the mailbox drains: ${reply}`);
}

await main();
