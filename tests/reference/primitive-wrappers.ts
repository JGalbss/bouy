// Number, String, Boolean, and BigInt objects: new, ToObject, unwrapping
// for this values and ToPrimitive, and String objects' index properties.
const n = new Number(5);
const s = new String("héllo");
const b = new Boolean(false);
console.log(typeof n, n + 1, n.valueOf(), n.toFixed(1), n);
console.log(typeof s, s.length, s[1], s + "!", Object.keys(s), s);
console.log(typeof b, b ? "truthy" : "falsy", b.valueOf(), String(b), b);
console.log(
  Object.prototype.toString.call(n),
  Object.prototype.toString.call(s),
  Object.prototype.toString.call(b),
);
console.log(
  Object(1) instanceof Number,
  Object("x") instanceof String,
  Object(true) instanceof Boolean,
);
console.log(
  Number.prototype.toString.call(Object(255), 16),
  String.prototype.toUpperCase.call(Object("up")),
);
class Money extends Number {
  label(): string {
    return "$" + this.toFixed(2);
  }
}
console.log(new Money(3.5).label(), new Money(2) instanceof Number);
try {
  Number.prototype.valueOf.call("5");
} catch (error) {
  console.log((error as Error).name);
}
const sloppyDelete = Function("o", "return [delete o?.b, delete o?.missing, delete 'foo'.length]");
console.log(sloppyDelete({ b: 1 }), sloppyDelete(undefined));
try {
  Function("'use strict'; return delete 'foo'.length")();
} catch (error) {
  console.log("strict delete of a string's length:", (error as Error).name);
}
