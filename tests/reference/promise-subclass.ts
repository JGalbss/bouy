// A Promise subclass: new, then, and the statics construct the subclass through NewTarget,
// Symbol.species, and `this`, and the combinators step the iterator one value at a time.
type Executor<T> = (
  resolve: (value: T | PromiseLike<T>) => void,
  reject: (reason?: unknown) => void,
) => void;

class Tracked<T> extends Promise<T> {
  static made = 0;
  constructor(executor: Executor<T>) {
    super(executor);
    Tracked.made++;
  }
}

class NoResolve<T> extends Promise<T> {
  static resolve(): never {
    throw new Error("no resolve");
  }
}

async function main() {
  const p = new Tracked<number>((resolve) => resolve(1));
  console.log(p instanceof Tracked, p instanceof Promise, Tracked.made);
  const q = p.then((v) => v + 1);
  console.log(q instanceof Tracked, Tracked.made);
  console.log(await q, Tracked.made);
  console.log(Tracked.resolve(3) instanceof Tracked, Tracked.all([1, 2]) instanceof Tracked);
  console.log(Promise[Symbol.species] === Promise, Tracked[Symbol.species] === Tracked);

  new Promise((resolve, reject) => {
    console.log(resolve.length, JSON.stringify(resolve.name), reject.length);
  });

  console.log(await Promise.try((a: number, b: number) => a + b, 2, 3));
  const failed = Promise.try(() => {
    throw new Error("thrown in try");
  });
  console.log(await failed.catch((e: Error) => e.message));

  let steps = 0;
  let closed = false;
  const endless = {
    [Symbol.iterator]() {
      return {
        next: () => ({ done: false, value: ++steps }),
        return: () => {
          closed = true;
          return {};
        },
      };
    },
  };
  await NoResolve.all(endless).catch((e: Error) => console.log(e.message, steps, closed));
}
main();
