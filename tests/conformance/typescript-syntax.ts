import type { Readable } from "node:stream";

type Pair<A, B> = { first: A; second: B };
interface Shape {
  kind: "circle" | "square";
  size: number;
}
declare const injected: number;

function identity<T>(value: T): T {
  return value;
}

function overloaded(value: string): string;
function overloaded(value: number): number;
function overloaded(value: string | number): string | number {
  return typeof value === "string" ? value.toUpperCase() : value * 2;
}

function area(shape: Shape): number {
  switch (shape.kind) {
    case "circle":
      return Math.round(Math.PI * shape.size ** 2);
    case "square":
      return shape.size ** 2;
  }
}

function pair<A, B>(first: A, second: B): Pair<A, B> {
  return { first, second };
}

const config = { retries: 3, name: "svc" } satisfies { retries: number; name: string };
const maybe = (globalValue() as string | undefined)!;

function globalValue(): unknown {
  return "present";
}

function main(): void {
  console.log(identity<number>(5), identity("x"));
  console.log(overloaded("abc"), overloaded(21));
  console.log(area({ kind: "circle", size: 2 }), area({ kind: "square", size: 3 } as Shape));
  const p = pair<string, number>("a", 1);
  console.log(p.first, p.second);
  console.log(config.retries, config.name, maybe);
  const nums = [1, 2, 3] as number[];
  console.log(nums.length);
  let late!: number;
  late = 4;
  console.log(late);
}

main();
