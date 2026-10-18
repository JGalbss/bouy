import { inspect, spawn } from "buoy";

class Cell {
  #value: number;

  constructor(value: number) {
    this.#value = value;
  }

  read(): number {
    return this.#value;
  }
}

async function main(): Promise<void> {
  const cells = [];
  for (let i = 0; i < 10000; i++) {
    cells.push(spawn(Cell, { args: [i] }));
  }
  let sum = 0;
  for (const cell of cells) {
    sum += await cell.read();
  }
  console.log(`${inspect().length} actors answered; the sum is ${sum}`);
  const values = await Promise.all(cells.map((cell) => cell.read()));
  console.log(`in parallel: ${values.length} answers, last ${values[values.length - 1]}`);
}

await main();
