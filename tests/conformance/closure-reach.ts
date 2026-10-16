// A write that a `return` keeps from running after a closure exists does not stop the
// closure from reading the variable.

function scale(items: number[], factor: number): number[] {
  if (items.length > 0) return items.map((item) => item * factor);
  factor = 0;
  return [factor];
}

function firstAbove(items: number[], limit: number): number {
  for (const item of items) {
    if (item > limit) return [item].map((found) => found + limit)[0];
    limit += 1;
  }
  return -1;
}

console.log(scale([1, 2], 3), scale([], 3));
console.log(firstAbove([1, 5, 9], 3));
