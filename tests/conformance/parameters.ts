function greet(name: string, greeting = "Hello", punctuation = "!"): string {
  return `${greeting}, ${name}${punctuation}`;
}

function sum(...numbers: number[]): number {
  return numbers.reduce((total, n) => total + n, 0);
}

function describe(first: string, ...others: string[]): string {
  return `${first} and ${others.length} others: ${others.join("/")}`;
}

function defaultsFromEarlier(a: number, b = a * 2, c = a + b): number {
  return a + b + c;
}

function optional(value?: number): string {
  return value === undefined ? "missing" : `got ${value}`;
}

function main(): void {
  console.log(greet("Ann"), greet("Bob", "Hi"), greet("Cid", undefined, "?"));
  console.log(sum(), sum(1), sum(1, 2, 3, 4));
  const values = [5, 6, 7];
  console.log(sum(...values), sum(1, ...values, 10));
  console.log(describe("x"), describe("x", "y", "z"));
  console.log(defaultsFromEarlier(1), defaultsFromEarlier(1, 1), defaultsFromEarlier(1, 1, 1));
  console.log(optional(), optional(0), optional(3));
  console.log(Math.max(...values, 2));
}

main();
