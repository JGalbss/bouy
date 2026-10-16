function fib(n: number): number {
  return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

function isEven(n: number): boolean {
  return n === 0 ? true : isOdd(n - 1);
}

function isOdd(n: number): boolean {
  return n === 0 ? false : isEven(n - 1);
}

function factorial(n: number): number {
  if (n <= 1) return 1;
  return n * factorial(n - 1);
}

function power(base: number, exponent: number): number {
  if (exponent === 0) return 1;
  const half = power(base, Math.floor(exponent / 2));
  return exponent % 2 === 0 ? half * half : half * half * base;
}

function permutations(items: string[]): string[] {
  if (items.length <= 1) return [items.join("")];
  const result: string[] = [];
  for (let i = 0; i < items.length; i++) {
    const rest = [...items.slice(0, i), ...items.slice(i + 1)];
    for (const tail of permutations(rest)) {
      result.push(items[i] + tail);
    }
  }
  return result;
}

function depth(tree: unknown): number {
  if (!Array.isArray(tree)) return 0;
  let deepest = 0;
  for (const child of tree) {
    deepest = Math.max(deepest, depth(child));
  }
  return deepest + 1;
}

function main(): void {
  console.log(fib(20), fib(1), fib(0));
  console.log(isEven(10), isOdd(7), isEven(3));
  console.log(factorial(20), factorial(15));
  console.log(power(2, 30), power(3, 5));
  console.log(permutations(["a", "b", "c"]).join(","));
  console.log(depth([1, [2, [3]], []]), depth(5));
  let sum = 0;
  for (let i = 0; i < 25; i++) sum += fib(i);
  console.log(sum);
}

main();
