import { child, inspect, supervise } from "bouy";

class Worker {
  #count = 0;

  bump(): number {
    this.#count++;
    return this.#count;
  }

  fail(): void {
    throw new Error("lost the connection");
  }
}

async function main(): Promise<void> {
  const team = supervise({
    strategy: "one-for-all",
    children: { reader: child(Worker), writer: child(Worker) },
  });
  await team.reader.bump();
  await team.reader.bump();
  await team.writer.bump();
  try {
    await team.reader.fail();
  } catch (error) {
    console.log(`${error._tag}: ${error.message}`);
  }
  // one-for-all restarts every child, so both start again from a fresh state.
  console.log(`reader: ${await team.reader.bump()}`);
  console.log(`writer: ${await team.writer.bump()}`);
  for (const actor of inspect()) {
    console.log(`${actor.class} ${actor.name}: ${actor.status}, restarts ${actor.restarts}`);
  }
}

await main();
