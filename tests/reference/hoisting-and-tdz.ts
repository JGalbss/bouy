// Hoisted functions and closures that read bindings declared after them, the temporal dead
// zone, and the order of a method call.
import blockFunctions from "./modules/block-functions.cjs";
function outer(): number {
  function helper(): number {
    return config.scale * later();
  }
  const config = { scale: 3 };
  const later = (): number => offset + 1;
  const offset = 1;
  return helper();
}
console.log(outer());

const errorText = (run: () => unknown): string => {
  try {
    run();
    return "no error";
  } catch (error) {
    return `${(error as Error).constructor.name}: ${(error as Error).message}`;
  }
};
function deadZone(): string {
  const read = (): number => value;
  const before = errorText(read);
  const value = 7;
  return `${before} / ${read()}`;
}
console.log(deadZone());
function defaults(first = second, second = 1): number {
  return first + second;
}
console.log(
  errorText(() => defaults()),
  defaults(2),
);

const log: string[] = [];
const target = {
  get method(): (value: number) => number {
    log.push("get method");
    return (value: number) => value;
  },
};
const argument = (): number => {
  log.push("argument");
  return 1;
};
target.method(argument());
console.log(log.join(", "));
const empty = { nested: undefined as unknown as { call(value: unknown): void } };
let evaluated = false;
console.log(
  errorText(() => empty.nested.call((evaluated = true))),
  evaluated,
);
function declaredAfter(): number {
  const base = 40;
  function add(): number {
    return base + 2;
  }
  return add();
}
console.log(declaredAfter());
function constWrite(): string {
  const fixed = 1;
  return errorText(() => {
    (fixed as number) = 2;
  });
}
console.log(constWrite());
function varsReadEarly(): unknown[] {
  var later = (): number => value;
  var value = 5;
  function hoisted(): number {
    return value * 2;
  }
  return [later(), hoisted()];
}
console.log(varsReadEarly());
console.log("block functions", blockFunctions);
function shortCircuitWrites(): unknown[] {
  const off = false;
  const on = true;
  let named: unknown = null;
  let unnamed: unknown = null;
  named ??= function (): void {};
  (unnamed) ??= function (): void {};
  const outcomes: unknown[] = [];
  for (const attempt of [() => (off &&= true), () => (on ||= false), () => (on &&= false)]) {
    try {
      outcomes.push(attempt());
    } catch (error) {
      outcomes.push((error as Error).name);
    }
  }
  return [...outcomes, (named as () => void).name, (unnamed as () => void).name];
}
console.log(shortCircuitWrites());
// Sloppy block functions: the last of two declarations wins in the block, a labelled one
// is hoisted too, a case's function exists from the start of the switch, and the block
// of eval code binds its own function before the caller's variables.
console.log(
  Function("{ var first = f(); function f() { return 3; } function f() { return 4; } } return [first, f()];")(),
  Function("{ var early = g(); l: function g() { return 'g'; } } return early;")(),
  Function("switch (1) { case 1: var early = h(); case 2: function h() { return 'h'; } } return [early, h()];")(),
  Function("eval('{ var early = k(); function k() { return 7; } }'); return [early, k()];")(),
);
