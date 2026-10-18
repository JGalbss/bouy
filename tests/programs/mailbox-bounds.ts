import { cast, inspect, sleep, spawn, type Ref } from "buoy";

// Many senders at once cannot pass the capacity of a mailbox together: a
// reject mailbox takes exactly its capacity, and a backpressure mailbox holds
// at most its capacity plus one message for each blocked sender.

class Slow {
  block(ms: number): void {
    sleep(ms);
  }

  work(): void {}
}

class Watcher {
  #max = 0;

  watch(id: number, rounds: number): number {
    for (let i = 0; i < rounds; i++) {
      const entry = inspect().find((actor) => actor.id === id);
      if (entry !== undefined && entry.mailbox > this.#max) this.#max = entry.mailbox;
      sleep(2);
    }
    return this.#max;
  }
}

function sendThree(target: Ref<Slow>): number {
  cast(target).work();
  cast(target).work();
  cast(target).work();
  return 3;
}

async function main(): Promise<void> {
  const rejecting = spawn(Slow, { mailbox: { capacity: 5, overflow: "reject" } });
  cast(rejecting).block(1000);
  await sleep(50);
  const senders = Array.from({ length: 50 }, (_, i) => i);
  const results = await Promise.allSettled(senders.map(() => cast(rejecting).work()));
  const accepted = results.filter((result) => result.status === "fulfilled").length;
  const full = results.filter(
    (result) => result.status === "rejected" && result.reason._tag === "MailboxFull",
  ).length;
  console.log(`reject: accepted ${accepted}, MailboxFull ${full}`);

  const waiting = spawn(Slow, { mailbox: { capacity: 5 } });
  const watcher = spawn(Watcher);
  cast(waiting).block(300);
  await sleep(20);
  const [max] = await Promise.all([
    watcher.watch(2, 150),
    Promise.all(senders.map(() => sendThree(waiting))),
  ]);
  console.log(
    `backpressure: the mailbox stayed within capacity plus blocked senders: ${max <= 5 + 50}`,
  );
}

await main();
