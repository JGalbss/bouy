import { spawn } from "bouy";

class Greeter {
  #greeting: string;

  constructor(greeting: string) {
    this.#greeting = greeting;
  }

  greet(name: string): string {
    return `${this.#greeting}, ${name}!`;
  }
}

const greeter = spawn(Greeter, { args: ["Hello"] });
console.log(await greeter.greet("world"));
console.log(await greeter.greet("BEAM"));
