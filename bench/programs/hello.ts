import { spawn } from "bouy";

class Greeter {
  greet(name: string): string {
    return `Hello, ${name}!`;
  }
}

const greeter = spawn(Greeter);
console.log(await greeter.greet("Ada"));
