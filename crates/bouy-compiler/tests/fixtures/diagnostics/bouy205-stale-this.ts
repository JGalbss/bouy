export class Counter {
  count = 0;
  current = (): number => this.count;
  later = 1;

  inc(): number {
    this.count++;
    return this.current();
  }

  remember(): void {
    this.getter = () => this.count;
  }

  getter = (): number => 0;

  callbacks(): Array<() => number> {
    return [1, 2].map(() => 0).map(this.inc);
  }
}
