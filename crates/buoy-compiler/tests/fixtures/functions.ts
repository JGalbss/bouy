export function defaults(a: number, b = a * 2, ...rest: number[]): number {
  return a + b + rest.length;
}

export function closures(factor: number): (x: number) => number {
  const scale = (x: number) => x * factor;
  function offset(x: number): number {
    return x + 1;
  }
  return (x) => offset(scale(x));
}

export const arrow = (x: number): number => x + 1;

export function recursive(n: number): number {
  const fact = (k: number): number => (k <= 1 ? 1 : k * fact(k - 1));
  return fact(n);
}

export function callsValues(f: (x: number) => number, xs: number[]): number[] {
  return xs
    .map(f)
    .map(arrow)
    .concat([f(1), arrow(2), defaults(1)]);
}
