// An actor prints far more lines than a reader that stops after the first one takes.
import { spawn } from "bouy";

class Printer {
  print(n: number): number {
    for (let i = 0; i < n; i++) {
      console.log(`line ${i}`);
    }
    return n;
  }
}

const printer = spawn(Printer, {});
console.log(printer.print(200000));
