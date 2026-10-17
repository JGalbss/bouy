import { fromB } from "./cycle-b.ts";
export function fromA(): string {
  return "A";
}
export const viaB = fromB();
