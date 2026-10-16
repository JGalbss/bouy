export function parity(n: number): string {
  function isEven(k: number): boolean {
    return k === 0 ? true : isOdd(k - 1);
  }
  function isOdd(k: number): boolean {
    return k === 0 ? false : isEven(k - 1);
  }
  return isEven(n) ? "even" : "odd";
}

export function report(items: number[]): string {
  let total = 0;
  for (const item of items) total += item;
  return describe();
  function describe(): string {
    return `total ${total}`;
  }
}

export const factorial = function fact(k: number): number {
  return k <= 1 ? 1 : k * fact(k - 1);
};

export function make(E: new (message: string) => Error): Error {
  return new E("made");
}
