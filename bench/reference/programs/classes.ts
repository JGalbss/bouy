// Method calls through a two-level prototype chain on 1,000 instances of a derived class,
// 1,000,000 calls in all. Value semantics has no class inheritance, so this one runs under
// node and `bouy run --semantics reference` only.
class Figure {
  area(): number {
    return 0;
  }
  scaled(k: number): number {
    return this.area() * k;
  }
}

class Rect extends Figure {
  w: number;
  h: number;
  constructor(w: number, h: number) {
    super();
    this.w = w;
    this.h = h;
  }
  area(): number {
    return this.w * this.h;
  }
}

function measure(rounds: number): string {
  const figures: Figure[] = [];
  for (let i = 0; i < 1000; i++) figures.push(new Rect(i % 7, i % 5));
  const start = Date.now();
  let total = 0;
  for (let round = 0; round < rounds; round++) {
    for (const f of figures) total += f.scaled(2);
  }
  const end = Date.now();
  return JSON.stringify({ bench: "classes", n: rounds * 1000, total_ms: end - start, check: total });
}

console.log(measure(1000));
