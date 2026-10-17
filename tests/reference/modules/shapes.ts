export { count as total, increment } from "./counter.ts";
export * from "./colors.ts";
export * as colors from "./colors.ts";
const secret = 42;
export { secret as "the answer" };
export default function area(width: number, height: number): number {
  return width * height;
}
