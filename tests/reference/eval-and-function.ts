// eval and the Function constructor: code that the program makes at run time.
const add = new Function("a", "b", "return a + b") as (a: number, b: number) => number;
console.log(add(2, 3), add.name, add.length);
const global = Function("return this")() as typeof globalThis;
console.log(global === globalThis, typeof Function("'use strict'; return this")());
console.log(eval("1 + 2"), eval("[1, 2].map((n) => n * 10)").join(","));
const indirect = eval;
indirect("var madeGlobal = 'global'");
console.log((globalThis as { madeGlobal?: string }).madeGlobal);
eval("var strictLocal = 1");
console.log(typeof (globalThis as { strictLocal?: number }).strictLocal);
const errorName = (run: () => unknown): string => {
  try {
    run();
    return "no error";
  } catch (error) {
    return (error as Error).constructor.name;
  }
};
console.log(
  errorName(() => eval("let let = 1")),
  errorName(() => Function("}, function() {")),
);
console.log(eval(42 as unknown as string), Function()());
const made = eval("(function named(x) { return x * 2; })") as (x: number) => number;
console.log(
  made(4),
  made.toString(),
  "|",
  new Function("a", "return a").toString().split("\n").join("\\n"),
);
function locals(a: number): unknown[] {
  let x = 1;
  eval("x = x + a; var hidden = 3;");
  const inner = (): unknown => eval("x * 10 + arguments.length");
  return [x, eval("typeof hidden"), inner()];
}
console.log(locals(5));
const Made = Function("function f() { this.p = 1; } return f")() as new () => { p: number };
console.log(Function("return typeof anonymous")(), new Made().p);
// Sloppy code may assign to a call: the call runs, then a ReferenceError. A logical
// assignment rejects the target when it parses. (Strict code rejects it too, as test262
// requires, where V8 throws when it runs.)
const callTargets = [
  "var calls = 0; function f() { calls++; } try { f() = 1; } catch (e) { return [e.name, calls]; }",
  "function f() {} try { for (f() in { a: 1 }) {} } catch (e) { return e.name; }",
  "function f() {} f() &&= 1;",
].map((body) => {
  try {
    return Function(body)();
  } catch (error) {
    return (error as Error).name;
  }
});
console.log(callTargets);
// `let` is a label in sloppy code, and a reserved word in strict code.
const letLabels = ["let: 42", "l\\u0065t: 43", "'use strict'; let: 44"].map((source) => {
  try {
    return (0, eval)(source);
  } catch (error) {
    return (error as Error).name;
  }
});
console.log(letLabels);
