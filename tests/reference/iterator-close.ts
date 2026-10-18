// The iterator protocol closes an iterator that a loop or a pattern leaves early:
// break, return, throw, and destructuring call its return method, and a generator runs
// its finally blocks.
function* inner() {
  try {
    yield 1;
    yield 2;
  } finally {
    console.log("inner finally");
  }
  return "inner result";
}
function* outer() {
  const result = yield* inner();
  console.log("delegated", result);
  yield* [3, 4];
  return 5;
}
console.log([...outer()]);
const delegating = outer();
console.log(delegating.next().value, delegating.return(9), delegating.next());

function* cleanup() {
  try {
    yield "a";
  } finally {
    console.log("cleanup ran");
  }
}
const early = cleanup();
early.next();
console.log(early.return(7));

function* catching() {
  while (true) {
    try {
      yield 1;
    } catch (error) {
      console.log("caught", error);
      return "done";
    }
  }
}
const thrown = catching();
thrown.next();
console.log(thrown.throw("boom"));

function counted(limit: number) {
  return {
    [Symbol.iterator]() {
      let i = 0;
      return {
        next: () => ({ value: i++, done: i > limit }),
        return: () => {
          console.log("return called");
          return {};
        },
      };
    },
  };
}
for (const x of counted(5)) {
  if (x === 1) break;
}
try {
  for (const x of counted(5)) {
    throw new Error("thrown in the body at " + x);
  }
} catch (error) {
  console.log((error as Error).message);
}
function first(): number | undefined {
  for (const x of counted(5)) {
    return x;
  }
}
console.log("returned", first());
outerLoop: for (const a of [1, 2]) {
  for (const b of counted(5)) {
    if (b === 1) continue outerLoop;
    console.log("pair", a, b);
  }
}

const [p, q] = counted(5);
console.log("pattern", p, q);
const [r, s = 10, t = 20] = counted(1);
console.log("defaults", r, s, t);
try {
  const [
    x = (() => {
      throw new Error("default threw");
    })(),
  ] = counted(5);
  console.log(x);
} catch (error) {
  console.log((error as Error).message);
}
const [] = counted(3);

function* conditional(flag: boolean) {
  const value = flag ? yield "asked" : "not asked";
  console.log("conditional", value);
}
const asking = conditional(true);
console.log(asking.next().value);
asking.next("answer");
[...conditional(false)];

let closes = 0;
const endless = {
  [Symbol.iterator]() {
    return { next: () => ({ done: false, value: undefined }), return: () => (closes++, {}) };
  },
};
function* patternYield() {
  [{} = yield] = endless as Iterable<any>;
}
const paused = patternYield();
paused.next();
console.log(paused.return(5), "closes:", closes);
function brokenReturn(): Iterable<unknown> {
  return {
    [Symbol.iterator]() {
      let first = true;
      const iterator = {
        next: () => (first ? ((first = false), { value: [{}, {}], done: false }) : { value: undefined, done: true }),
      };
      Object.defineProperty(iterator, "return", {
        get() {
          throw "return getter throws";
        },
      });
      return iterator as Iterator<unknown>;
    },
  };
}
class FailingWeakMap extends WeakMap<object, unknown> {
  override set(): this {
    throw "set throws";
  }
}
class FailingWeakSet extends WeakSet<object> {
  override add(): this {
    throw "add throws";
  }
}
for (const Collection of [FailingWeakMap, FailingWeakSet]) {
  try {
    new Collection(brokenReturn() as Iterable<never>);
  } catch (error) {
    console.log(Collection.name, error);
  }
}
let iteratedThis = "";
Object.defineProperty(Number.prototype, Symbol.iterator, {
  configurable: true,
  value(this: number) {
    iteratedThis = typeof this;
    return [][Symbol.iterator]();
  },
});
console.log(new Map(0 as unknown as Iterable<[unknown, unknown]>).size, iteratedThis);
delete (Number.prototype as unknown as Record<symbol, unknown>)[Symbol.iterator];
