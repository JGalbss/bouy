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
