// Function objects: name and length, bind, call and apply, new.target, and instanceof.
const named = function () {};
const arrow = (a: number, b = 2, ...rest: number[]) => a + b + rest.length;
let assigned: () => void;
assigned = () => {};
const symbolKey = Symbol("tag");
const holder = {
  method(x: number) {
    return x;
  },
  property: function () {},
  [symbolKey]: () => {},
  get value() {
    return 1;
  },
};
const { fallback = () => {} } = {} as { fallback?: () => void };
console.log(named.name, arrow.name, arrow.length, assigned.name, fallback.name);
console.log(holder.method.name, holder.method.length, holder.property.name, holder[symbolKey].name);
console.log(
  Object.getOwnPropertyDescriptor(holder, "value")?.get?.name,
  Object.getOwnPropertyNames(arrow),
);
console.log(
  JSON.stringify(Object.getOwnPropertyDescriptor(named, "name")),
  JSON.stringify(Object.getOwnPropertyDescriptor(named, "length")),
);

function Point(this: { x: number; y: number }, x: number, y: number) {
  this.x = x;
  this.y = y;
  if (new.target === undefined) {
    return "called";
  }
}
const PointCtor = Point as unknown as new (x: number, y: number) => { x: number; y: number };
const point = new PointCtor(1, 2);
console.log(
  point.x + point.y,
  point instanceof PointCtor,
  Object.getPrototypeOf(point) === Point.prototype,
);
console.log((Point as unknown as (x: number, y: number) => unknown).call({}, 1, 2));
const BoundPoint = Point.bind(null, 10) as unknown as new (y: number) => { x: number; y: number };
const bound = new BoundPoint(20);
console.log(
  BoundPoint.name,
  BoundPoint.length,
  bound.x,
  bound.y,
  bound instanceof PointCtor,
  "prototype" in BoundPoint,
);

function collect(this: unknown, ...items: unknown[]) {
  return `${typeof this}:${items.join("/")}`;
}
console.log(
  collect.call("s", 1, 2),
  collect.apply(null, { length: 2, 0: "a", 1: "b" } as unknown as unknown[]),
);
const errorName = (run: () => unknown): string => {
  try {
    run();
    return "no error";
  } catch (error) {
    return (error as Error).constructor.name;
  }
};
console.log(
  errorName(() => new (arrow as unknown as new () => object)()),
  errorName(() => new (holder.method as unknown as new () => object)()),
);
function* generator() {
  yield 1;
}
async function later() {}
console.log(
  errorName(() => new (generator as unknown as new () => object)()),
  errorName(() => new (later as unknown as new () => object)()),
);
console.log("prototype" in generator, "prototype" in later, "prototype" in arrow);

const Even = {
  [Symbol.hasInstance](value: unknown) {
    return typeof value === "number" && value % 2 === 0;
  },
};
console.log(
  (2 as unknown) instanceof (Even as unknown as Function),
  (3 as unknown) instanceof (Even as unknown as Function),
);
console.log(
  errorName(() => ({}) instanceof (Even.constructor as unknown as Function)),
  errorName(() => ({}) instanceof ({} as Function)),
);
console.log(Function.prototype.toString.call(Math.max), Function.prototype.name === "");
const fact = function self(n: number): number {
  return n <= 1 ? 1 : n * self(n - 1);
};
console.log(fact(6));
