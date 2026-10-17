// Bindings that code reads before their declaration runs: a hoisted function reads a
// later const, a function reads a class declared after it, and a read before the
// declaration throws a ReferenceError (the temporal dead zone).
function configured(): number {
  const config = { x: 42 };
  function read(): number {
    return config.x;
  }
  return read();
}
console.log(configured());

function tooEarly(): string {
  let result: string;
  try {
    result = String(peek());
  } catch (error) {
    result = (error as Error).constructor.name;
  }
  const later = 1;
  return `${result}, then ${peek()}`;
  function peek(): number {
    return later;
  }
}
console.log(tooEarly());

function classAfter(): number {
  function make(): { v: number } {
    return new Made();
  }
  class Made {
    v = 3;
  }
  return make().v;
}
console.log(classAfter());

function defaults(a = b, b = 1): number {
  return a;
}
try {
  defaults();
} catch (error) {
  console.log("default before its parameter:", (error as Error).constructor.name);
}
console.log(defaults(5));

function perIteration(): number[] {
  const out: number[] = [];
  for (let i = 0; i < 3; i++) {
    const read = () => doubled;
    const doubled = i * 2;
    out.push(read());
  }
  return out;
}
console.log(perIteration());

let shadowed = "outside";
let probe: () => string = () => "unset";
for (const shadowed of ((probe = () => typeof shadowed), [1])) {
  console.log("loop binding", shadowed);
}
try {
  probe();
} catch (error) {
  console.log("loop head:", (error as Error).constructor.name, shadowed);
}

try {
  readModuleLater();
} catch (error) {
  console.log("module binding before its declaration:", (error as Error).constructor.name);
}
const moduleLater = ["module", "later"].join(" ");
console.log(readModuleLater());
function readModuleLater(): string {
  return moduleLater;
}

function cases(n: number): string {
  switch (n) {
    case 1:
      const word = "one";
      return word;
    case 2:
      try {
        return word;
      } catch (error) {
        return (error as Error).constructor.name;
      }
    default:
      return "other";
  }
}
console.log("switch cases share a scope:", cases(1), cases(2), cases(3));

// A hoisted function that writes a `let` before its declaration runs throws too.
function earlyWrite(): string {
  let before: string;
  try {
    assign(1);
    before = "no error";
  } catch (error) {
    before = (error as Error).constructor.name;
  }
  let later = 0;
  assign(2);
  return `${before}, then ${later}`;
  function assign(value: number): void {
    later = value;
  }
}
console.log(earlyWrite());

// The `extends` clause of a class sees the class's own binding once the class exists,
// apart from the binding outside the class.
function heritageBinding(): string {
  let probeDeclared = (): unknown => undefined;
  let probeExpression = (): unknown => undefined;
  class Base {}
  class Declared extends ((probeDeclared = () => Declared), Base) {}
  let Expressed = class Inner extends ((probeExpression = () => Inner), Base) {};
  const original = Expressed;
  Expressed = class extends Base {};
  return `${probeDeclared() === Declared}, ${probeExpression() === original}, ${probeExpression() === Expressed}`;
}
console.log(heritageBinding());
