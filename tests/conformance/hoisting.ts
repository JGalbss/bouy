// Function declarations inside functions are available before their declaration and can
// call each other. A named function expression can call itself, and a module-level const
// can hold closures that read the const or a const declared after it.

function parity(n: number): string {
  function isEven(k: number): boolean {
    return k === 0 ? true : isOdd(k - 1);
  }
  function isOdd(k: number): boolean {
    return k === 0 ? false : isEven(k - 1);
  }
  return isEven(n) ? "even" : "odd";
}

function callBeforeDeclaration(): number {
  return inner(2);
  function inner(x: number): number {
    return x * 2;
  }
}

function readsLaterConst(): string {
  function describe(): string {
    return "count=" + count;
  }
  const count = 5;
  return describe();
}

function helpersAtTheBottom(items: number[]): string {
  let total = 0;
  for (const item of items) total += item;
  return report();
  function report(): string {
    return `total ${total} of ${format(items.length)}`;
  }
  function format(n: number): string {
    return n === 1 ? "1 item" : `${n} items`;
  }
}

function namedExpression(): number {
  const fact = function self(k: number): number {
    return k <= 1 ? 1 : k * self(k - 1);
  };
  return fact(5);
}

const moduleFact = function factorial(k: number): number {
  return k <= 1 ? 1 : k * factorial(k - 1);
};

const api = {
  double: (n: number): number => n * 2,
  quad: (n: number): number => api.double(api.double(n)),
};

const site = {
  url: (path: string): string => BASE + path,
};
const BASE = ["https://h", "x"].join("/");

function traced(f: (n: number) => number): (n: number) => number {
  return (n) => f(n);
}
const fib = traced((n: number): number => (n < 2 ? n : fib(n - 1) + fib(n - 2)));

console.log(parity(7), parity(10));
console.log(callBeforeDeclaration(), readsLaterConst());
console.log(helpersAtTheBottom([1, 2, 3]), helpersAtTheBottom([4]));
console.log(namedExpression(), moduleFact(6));
console.log(api.quad(3), site.url("/y"), fib(10));
