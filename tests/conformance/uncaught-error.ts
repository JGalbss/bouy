function divide(a: number, b: number): number {
  if (b === 0) {
    throw new RangeError("cannot divide by zero");
  }
  return a / b;
}

console.log("before", divide(10, 2));
console.log("still running");
divide(1, 0);
console.log("never printed");
