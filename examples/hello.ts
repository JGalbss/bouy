import { inspect, spawn, supervise, child } from "bouy";

class Greeter {
  readonly #greeted: Array<string> = [];

  async greet(name: string): Promise<string> {
    this.#greeted.push(name);
    let checksum = 0;
    for (let index = 0; index < 1_000; index += 1) checksum += index;
    return `Hello, ${name}! (${this.#greeted.length} greeted, checksum ${checksum})`;
  }

  fail(): never {
    throw new Error("the greeter tripped");
  }
}

const greeter = spawn(Greeter);
console.log(await greeter.greet("Ada"));
console.log(await greeter.greet("Grace"));

const team = supervise({ strategy: "one-for-one", children: { greeter: child(Greeter) } });
await team.greeter.fail().catch((error: Error) => console.log(`caught: ${error.message}`));
console.log(await team.greeter.greet("Linus"));
console.log(
  inspect()
    .map((actor) => `${actor.name}: ${actor.status}, restarts ${actor.restarts}`)
    .join("\n"),
);
