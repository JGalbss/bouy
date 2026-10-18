// Direct eval in sloppy functions: the `var` names and functions of the eval code bind in
// the caller's function, not on the global object, and later code and later evals see
// them. Indirect eval makes the sloppy functions, as this module is strict.
const sloppy = (source: string): ((...args: unknown[]) => unknown) => (0, eval)(`(${source})`);
const outer = "outer";
const scopes = {
  newVar: sloppy("function () { eval('var x = 1'); return [typeof x, x]; }"),
  newFunction: sloppy("function () { eval('function g() { return \"g\"; }'); return g(); }"),
  existing: sloppy("function () { var w = 1; eval('var w = 2'); return w; }"),
  shadowsOuter: sloppy(
    "function () { var v = 'outer'; return [(function () { eval('var v = \"inner\"'); return v; })(), v]; }",
  ),
  closure: sloppy(
    "function () { eval('var n = 1'); var bump = function () { return n++; }; bump(); return bump(); }",
  ),
  deleted: sloppy(
    "function () { eval('var z = 1'); var before = typeof z; delete z; return [before, typeof z]; }",
  ),
  laterEval: sloppy("function () { eval('var q = 5'); return eval('q * 2'); }"),
  nestedEval: sloppy("function () { eval(\"eval('var deep = 3')\"); return deep; }"),
  strictKeeps: sloppy("function () { eval('\"use strict\"; var s = 1'); return typeof s; }"),
  arrowOwn: sloppy("function () { (() => eval('var r = 1'))(); return typeof r; }"),
  capturesCaller: sloppy(
    "function (a) { return eval('function inner() { return a * 2; } inner()'); }",
  ),
  classCaptures: sloppy(
    "function (a) { return eval('class K { m() { return a; } } new K().m()'); }",
  ),
  // A function of the eval code reads a `var` of the same code.
  functionReadsVar: sloppy(
    "function () { return eval('var c = 4; function readC() { return c; } readC()'); }",
  ),
  earlyLexical: sloppy(
    "function () { eval('function early() { return late; } let late = 5;'); return early(); }",
  ),
  deadZone: sloppy(
    "function () { var e; try { eval('later'); } catch (error) { e = error.constructor.name; } let later = 1; return [e, eval('later')]; }",
  ),
  lexicalStays: sloppy("function () { eval('let l = 1; var m = l + 1'); return [typeof l, m]; }"),
  withObject: sloppy("function () { var o = { p: 'from with' }; with (o) { return eval('p'); } }"),
  // The update of a loop around a `with` is outside its object.
  withInLoop: sloppy(
    "function () { var env = { i: 'shadow' }; var seen = []; for (let i = 0; i < 2; i++) { with (env) { seen.push(i); } } return seen; }",
  ),
  thisValue: sloppy("function () { return eval('this') === globalThis; }"),
  callThis: sloppy(
    "function () { eval('function me() { return this; }'); return me() === globalThis; }",
  ),
};
for (const [name, run] of Object.entries(scopes)) {
  console.log(name, run(21));
}
console.log(typeof (globalThis as Record<string, unknown>).x, outer);
console.log((0, eval)("var g = 6; function readG() { return g; } readG()"));
