enum Color {
  Red,
}

export class Shape {
  static count = 0;
  get area(): number {
    return 0;
  }
}

export class Square extends Shape {}

export function* numbers(): Generator<number> {
  yield 1;
}

export function legacy(): number {
  var x = 1;
  outer: for (const y of [1]) {
    break outer;
  }
  return x + /ab+c/.exec("abc")!.length;
}

export function chains(promise: Promise<number>): void {
  promise.then((value) => console.log(value));
  new Promise((resolve) => resolve(1));
}

export function fallThrough(n: number): number {
  let x = 0;
  switch (n) {
    case 1:
      x = 1;
    case 2:
      x = 2;
      break;
  }
  return x + arguments.length;
}

console.log(Color.Red);

import legacy = require("./legacy.cjs");

export class Decorated {
  @logged
  run(): void {}
}

function logged(): void {}

console.log(legacy);
