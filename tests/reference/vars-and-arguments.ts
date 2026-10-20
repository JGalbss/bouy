// `var` names exist from the start of their function, `arguments` holds the arguments of
// a call, and a function declaration has a prototype object that `new` uses.
import legacyVarStatements from "./modules/legacy-var-statements.cjs";

function total() {
  let sum = 0;
  for (var i = 0; i < arguments.length; i++) {
    sum += arguments[i];
  }
  return [sum, i, arguments.length, typeof arguments, Object.prototype.toString.call(arguments)];
}
console.log(total(1, 2, 3), total());

function hoisted(flag: boolean) {
  const before = typeof value;
  if (flag) {
    var value = "set";
  }
  return [before, value];
}
console.log(hoisted(true), hoisted(false));

function counter() {
  const read = () => count;
  var count = 1;
  count += 1;
  var count;
  return read();
}
console.log(counter());

function spread() {
  const inner = () => arguments[0];
  return [inner(), [...arguments].join("-")];
}
console.log(spread("a", "b"));

function Point(this: { x: number; y: number }, x: number, y: number) {
  this.x = x;
  this.y = y;
}
Point.prototype.sum = function (this: { x: number; y: number }) {
  return this.x + this.y;
};
const point = new (Point as any)(2, 3);
console.log(point.sum(), point instanceof Point, Point.prototype.constructor === Point);
console.log(Point.name, Point.length, Object.keys(Point.prototype));

for (var outer = 0; outer < 2; outer++) {
  var last = outer;
}
function readOuter() {
  return [outer, last];
}
console.log(readOuter());
console.log("legacy var statements", legacyVarStatements);
