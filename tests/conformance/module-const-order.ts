// A module-level const that a function reads before its declaration runs
// throws a ReferenceError, as in JavaScript. (The compiler inlines a literal
// initializer, so this program computes the value.)

function show(): number {
  return LIMIT * 2;
}

try {
  show();
} catch (e) {
  console.log((e as Error).name + ": " + (e as Error).message, e instanceof Error);
}

const LIMIT = Number("21");
console.log(show());
