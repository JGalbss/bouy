// User error classes keep the `cause` option, with or without their own constructor, and
// an overloaded constructor runs its implementation.

class Wrapped extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
  }
}

class Plain extends Error {}

class BadInput extends TypeError {}

class AppError extends Error {
  code = 0;
  constructor(message: string);
  constructor(message: string, code: number);
  constructor(message: string, code?: number) {
    super(message);
    this.code = code ?? 1;
  }
}

const wrapped = new Wrapped("outer", { cause: "disk full" });
const plain = new Plain("outer", { cause: "net down" });
const none = new Plain("no options");
const undefinedCause = new Plain("explicit", { cause: undefined });
console.log(wrapped.message, wrapped.cause, plain.cause, none.cause);
console.log("cause" in none, "cause" in undefinedCause, "cause" in plain);
const bad = new BadInput("x");
console.log(bad instanceof TypeError, bad instanceof Error, bad instanceof RangeError);
const app = new AppError("bad", 42);
const defaulted = new AppError("worse");
console.log(app.message, app.code, defaulted.code);

// `new` on a class value: a parameter, an array item, and a global namespace.
class NotFound extends Error {}
function make(E: new (message: string) => Error, message: string): Error {
  return new E(message);
}
const made = make(NotFound, "a");
const ranged = new [TypeError, RangeError][1]("b");
const Store = Map;
const store = new Store<string, number>([["k", 1]]);
console.log(made instanceof NotFound, made.message, ranged instanceof RangeError, store.get("k"));
try {
  const value: any = 5;
  new value();
} catch (error) {
  console.log((error as Error).name);
}
