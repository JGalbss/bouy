// Function names: NamedEvaluation names anonymous functions, arrows, and classes after
// their binding, and the name of a function expression refers to the function inside it.
import DefaultWithName from "./modules/default-static-name.ts";
const factorial = function fact(n: number): number {
  return n <= 1 ? 1 : n * fact(n - 1);
};
console.log(factorial(5), factorial.name);

const arrow = () => 1;
const asyncArrow = async () => 1;
const anonymous = function () {};
const Klass = class {};
let assigned;
assigned = () => 2;
const { fromDefault = () => 3 } = {} as { fromDefault?: () => number };
const literal = { method() {}, property: () => 4, [Symbol.iterator]: function () {} };
console.log(arrow.name, asyncArrow.name, anonymous.name, Klass.name, (assigned as any).name);
console.log(fromDefault.name, literal.method.name, literal.property.name);
console.log(literal[Symbol.iterator].name, (() => {}).name === "", (() => {}).length);

function* countdown(this: unknown, from: number): Generator<number> {
  if (from > 0) {
    yield from;
    yield* countdown(from - 1);
  }
}
console.log([...countdown(3)], countdown.name, countdown.length);

const named = DefaultWithName as unknown as { name(): string };
console.log(typeof named.name, named.name());
