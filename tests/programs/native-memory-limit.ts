import { spawn } from "buoy";

class Cell {
  next: Cell | null;
  value: number;
  constructor(value: number, next: Cell | null) {
    this.value = value;
    this.next = next;
  }
}

// `fill` is an island. Each of 8 actors runs it at once and holds about 60 MB of cells in
// the heap of its native run while it walks them. BUOY_MAX_MEMORY counts these heaps as
// it counts the heaps of processes, so the VM stops.
function fill(n: number, rounds: number): number {
  let head: Cell | null = null;
  for (let i = 0; i < n; i++) head = new Cell(i, head);
  let sum = 0;
  for (let round = 0; round < rounds; round++) {
    let cell = head;
    while (cell !== null) {
      sum += cell.value;
      cell = cell.next;
    }
  }
  return sum;
}

class Filler {
  fill(n: number, rounds: number): number {
    return fill(n, rounds);
  }
}

async function main(): Promise<void> {
  const fillers = Array.from({ length: 8 }, () => spawn(Filler));
  const sums = await Promise.all(fillers.map((filler) => filler.fill(2_500_000, 200)));
  console.log(`${sums.length} runs ended`);
}

await main();
