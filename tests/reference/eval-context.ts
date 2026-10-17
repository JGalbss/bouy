// Direct eval sees the context of its call: super in methods, new.target in functions,
// super() in derived constructors, the private names of the classes around it, and the
// rule that a class field initializer may not read `arguments`.
const errorName = (run: () => unknown): string => {
  try {
    return String(run());
  } catch (error) {
    return (error as Error).constructor.name;
  }
};
const literal = {
  __proto__: { inherited: 262 },
  read() {
    return eval("super.inherited");
  },
  arrow() {
    return (() => eval("super.inherited"))();
  },
};
console.log(
  literal.read(),
  literal.arrow(),
  errorName(() => eval("super.inherited")),
);
function Target(this: unknown): unknown {
  return eval("new.target");
}
console.log(
  errorName(() => Target.call(undefined)),
  typeof new (Target as unknown as new () => object)(),
);
console.log(errorName(() => (0, eval)("new.target")));
class Base {
  get name(): string {
    return "base";
  }
}
class Fields extends Base {
  fromSuper = eval("super.name");
  target = eval("new.target");
}
const fields = new Fields();
console.log(fields.fromSuper, fields.target);
let ran = false;
class ReadsArguments {
  value = eval("ran = true; arguments");
}
class ArrowArguments {
  value = eval("() => arguments");
}
console.log(
  errorName(() => new ReadsArguments()),
  errorName(() => new ArrowArguments()),
  ran,
);
class CallsSuper extends Base {
  made: boolean;
  constructor() {
    eval("super()");
    this.made = eval("this instanceof CallsSuper");
  }
}
console.log(
  new CallsSuper().made,
  errorName(() => ({ m: () => eval("super()") }).m()),
);
class Counter {
  #count = 41;
  #step(): number {
    return 1;
  }
  static #made = "static";
  next(): unknown {
    return eval("this.#count += this.#step()");
  }
  has(other: object): unknown {
    return eval("#count in other");
  }
  kind(): unknown {
    return eval("Counter.#made");
  }
}
const counter = new Counter();
console.log(counter.next(), counter.has(counter), counter.has({}), counter.kind());
console.log(
  errorName(() => eval("this.#count")),
  errorName(() => counter.next.call({})),
);
// The name of a function expression is an immutable binding that eval code reads.
const nameReads = (): unknown[] => {
  const named = function ownName(): unknown[] {
    return [eval("ownName === named"), errorName(() => eval("ownName = 1"))];
  };
  return named();
};
console.log(nameReads());
// Source text that is only comments, or one regular expression literal, needs no module.
console.log(eval("// only a comment"), eval("/* block */"), eval("#!hashbang"), eval("#!\n1"));
const pattern = eval("/a[/]b/gi") as RegExp;
console.log(
  pattern.source,
  pattern.flags,
  errorName(() => eval("/a/gg")),
);
