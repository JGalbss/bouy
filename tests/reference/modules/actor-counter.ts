// An actor class in a module of its own, with the module state that it reads.
const step = 10;

export class Counter {
  total: number;
  constructor(start: number) {
    this.total = start;
  }
  add(): number {
    this.total += step;
    return this.total;
  }
}
