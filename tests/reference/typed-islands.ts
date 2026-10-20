// Typed code that the native tier runs: each function below that takes and returns
// numbers loops or calls, and reads and writes only numbers, booleans, and objects and
// arrays that it makes. Its results must equal Node's, on the fast path and on the paths
// where the native run gives up and the Erlang tier runs the call again.

const SCALE = 3;

function sumTo(n: number): number {
  let total = 0;
  for (let i = 0; i < n; i++) total += i * SCALE;
  return total;
}

function bits(n: number): number {
  let x = 0;
  for (let i = 0; i < n; i++) {
    x = (x ^ (i << 7)) + (i >>> 1) - (~i & 0xff);
    x = x | 0;
  }
  return x + (n >> 2) + (-1 >>> 0) + ((2 ** 31) | 0) + ((2 ** 32 + 5) >> 0);
}

function edges(kind: number): number {
  let zero = 0;
  for (let i = 0; i < 3; i++) zero = zero * -1;
  if (kind === 0) return zero;
  if (kind === 1) return zero / zero;
  if (kind === 2) return 1 / zero;
  if (kind === 3) return -7 % 3;
  if (kind === 4) return 2 ** 0.5;
  return Math.max(Math.floor(-2.5), Math.ceil(-2.5)) + Math.round(-2.5) + Math.trunc(-2.7);
}

interface Shape {
  area(): number;
}

class Rect implements Shape {
  w: number;
  h: number;

  constructor(w: number, h: number) {
    this.w = w;
    this.h = h;
  }

  area(): number {
    return this.w * this.h;
  }
}

class Square extends Rect {
  constructor(side: number) {
    super(side, side);
  }

  override area(): number {
    return super.area() + 1;
  }
}

class Circle implements Shape {
  r: number;

  constructor(r: number) {
    this.r = r;
  }

  area(): number {
    return Math.PI * this.r * this.r;
  }
}

function shapes(n: number): number {
  const all: Shape[] = [];
  for (let i = 0; i < n; i++) {
    all.push(new Rect(i, 2));
    all.push(new Square(i));
    all.push(new Circle(i % 3));
  }
  let total = 0;
  for (const shape of all) total += shape.area();
  return Math.round(total * 1000) / 1000;
}

class Cell {
  value: number;
  next: Cell | null;

  constructor(value: number, next: Cell | null) {
    this.value = value;
    this.next = next;
  }
}

function listSum(n: number): number {
  let head: Cell | null = null;
  for (let i = 0; i < n; i++) head = new Cell(i, head);
  let total = 0;
  for (let cell = head; cell !== null; cell = cell.next) total += cell.value;
  return total;
}

function grade(n: number): number {
  let score = 0;
  for (let i = 0; i < n; i++) {
    switch (i % 5) {
      case 0:
        score += 1;
      case 1:
        score += 10;
        break;
      case 2: {
        score += 100;
        continue;
      }
      default:
        score += 1000;
    }
    score -= 1;
  }
  return score;
}

function failing(n: number): number {
  let total = 0;
  for (let i = 0; i < n; i++) {
    if (i === 5) throw new RangeError(`stop at ${i}`);
    total += i;
  }
  return total;
}

class Point {
  x: number;

  constructor(x: number) {
    this.x = x;
  }
}

function reach(n: number): number {
  const points = [new Point(1), new Point(2)];
  let total = 0;
  for (let i = 0; i <= n; i++) total += points[i].x;
  return total;
}

function past(n: number): number {
  const values: number[] = [1, 2];
  let total = 0;
  for (let i = 0; i < n; i++) total += values[i];
  return total;
}

class Counter {
  n = 0;

  step(): void {
    this.n += 1;
  }
}

function count(k: number): number {
  const counter = new Counter();
  for (let i = 0; i < k; i++) counter.step();
  return counter.n;
}

let factor = 2;

function scaled(n: number): number {
  let total = 0;
  for (let i = 0; i < n; i++) total += i * factor;
  return total;
}

function grid(n: number): boolean {
  const rows = new Array<number>(n).fill(0);
  for (let i = 0; i < n; i++) rows[i] = i * i;
  rows[n] = -1;
  let ok = rows.length === n + 1;
  for (let i = 0; i < n; i++) ok = ok && rows[i] === i * i;
  return ok;
}

console.log(sumTo(10), sumTo(100000), sumTo(0));
console.log(bits(1000), bits(7));
console.log(edges(0), edges(1), edges(2), edges(3), edges(4), edges(5));
console.log(shapes(10), shapes(0));
console.log(listSum(1000));
console.log(grade(23));
try {
  failing(10);
} catch (error) {
  console.log(error instanceof RangeError, (error as Error).message);
}
console.log(reach(1));
try {
  reach(2);
} catch (error) {
  console.log(error instanceof TypeError, (error as Error).message);
}
console.log(past(2), past(3));
console.log(count(10));
Counter.prototype.step = function (this: Counter): void {
  this.n += 2;
};
console.log(count(10));
console.log(scaled(4));
factor = 3;
console.log(scaled(4));
console.log(sumTo("4" as unknown as number), sumTo(4.5), sumTo(-1));
console.log(grid(50));
