import { fromA, viaB } from "./cycle-a.ts";
export function fromB(): string {
  return "B sees " + fromA();
}
let early: string;
try {
  early = String(viaB);
} catch (error) {
  early = (error as Error).name;
}
export { early };
