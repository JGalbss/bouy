// Symbol.iterator on a class drives for...of, spread, and Array.from.
class Range {
  readonly start: number;
  readonly end: number;
  constructor(start: number, end: number) {
    this.start = start;
    this.end = end;
  }
  [Symbol.iterator](): Iterator<number> {
    let current = this.start;
    const end = this.end;
    return {
      next: (): IteratorResult<number> => {
        if (current < end) return { value: current++, done: false };
        return { value: undefined, done: true };
      },
    };
  }
}

const r = new Range(1, 5);
const seen: number[] = [];
for (const n of r) seen.push(n * n);
console.log(seen, [...r], Array.from(r).length);

class Tree {
  children: Tree[] = [];
  label: string;
  constructor(label: string) {
    this.label = label;
  }
  add(child: Tree): this {
    this.children.push(child);
    return this;
  }
  *[Symbol.iterator](): Generator<string> {
    yield this.label;
    for (const child of this.children) {
      for (const label of child) yield label;
    }
  }
}
const tree = new Tree("root").add(new Tree("a").add(new Tree("a1"))).add(new Tree("b"));
console.log([...tree].join(" "));
