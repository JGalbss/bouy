export function members(): void {
  console.table([{ a: 1 }]);
  console.log(Object.own_entries({ b: 2 }));
}

export function temporaries(grid: number[][], flag: boolean): void {
  const a = [1];
  const b = [2];
  grid.at(0)!.push(7);
  (flag ? a : b).push(1);
}

export function globals(): void {
  // @ts-ignore
  undeclaredName = 5;
  console.log = () => {};
}

export function syntax(base: object, list: { items?: number[] } | undefined): unknown {
  for (var x of [1, 2]) {
    console.log(x);
  }
  list?.items.push(1);
  return { __proto__: base };
}

class Shadowed {}
export class Wrong extends Shadowed {}
export class NotImported extends Data.TaggedError("NotImported") {}

export default 42;
