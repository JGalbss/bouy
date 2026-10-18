import { helper, LIMIT, Shape } from "./imported.ts";
import * as imported from "./imported.ts";

const GREETING = "hello";
const TABLE = new Map([["a", 1]]);
const DERIVED = GREETING.length * LIMIT;
export const EXPORTED = 42;

export function useState(): unknown[] {
  return [GREETING, TABLE.get("a"), DERIVED, helper(1), imported.helper(2), imported.LIMIT, Shape];
}

console.log(GREETING, DERIVED);
