// Classes made where the code runs: class expressions, classes in functions, private
// names per evaluation, static blocks, accessors, super, new.target, and mixins.
function makeCounter(start: number) {
  return class Counter {
    #count = start;
    static made = 0;
    static {
      Counter.made++;
    }
    inc(): number {
      return ++this.#count;
    }
    get count(): number {
      return this.#count;
    }
    static has(o: object): boolean {
      return #count in o;
    }
  };
}
const A = makeCounter(1);
const B = makeCounter(10);
const a = new A();
const b = new B();
console.log(a.inc(), a.inc(), b.inc(), A.made, B.made, A.has(a), A.has(b), A === B);
try {
  A.prototype.inc.call(b);
} catch (error) {
  console.log("brand check:", (error as Error).constructor.name);
}

const anonymous = class {};
const methods = {
  m() {},
  get g() {
    return 1;
  },
  f: function () {},
  arrow: () => {},
};
const getter = Object.getOwnPropertyDescriptor(methods, "g")!.get!;
console.log(
  anonymous.name,
  A.name,
  methods.m.name,
  getter.name,
  methods.f.name,
  methods.arrow.name,
);
class Keys {
  static [Symbol.iterator]() {}
  static ["x" + 1](a: number, b: number) {
    return a + b;
  }
}
console.log(Keys[Symbol.iterator].name, Keys.x1.name, Keys.x1.length);

class Base {
  x: number;
  constructor(x: number) {
    this.x = x;
  }
  who(): string {
    return "base";
  }
  static kind(): string {
    return "static base";
  }
}
class Derived extends Base {
  y = this.x * 2;
  constructor(x: number) {
    super(x + 1);
  }
  who(): string {
    return "derived > " + super.who();
  }
  static kind(): string {
    return "static derived > " + super.kind();
  }
}
const d = new Derived(1);
console.log(d.x, d.y, d.who(), Derived.kind(), d instanceof Base);

class Early extends Base {
  constructor() {
    // @ts-expect-error: this runs before super() on purpose.
    this.z = 1;
    super(0);
  }
}
try {
  new Early();
} catch (error) {
  console.log("before super:", (error as Error).constructor.name);
}

function Plain(this: unknown) {
  return new.target === undefined ? "called" : "constructed";
}
console.log(Plain.call(undefined), typeof new (Plain as any)());
class Target {
  target = new.target;
}
class SubTarget extends Target {}
console.log(new Target().target === undefined, new SubTarget() instanceof Target);

const mixin = <T extends new (...args: any[]) => object>(Super: T) =>
  class extends Super {
    mixed(): string {
      return "mixed";
    }
  };
class Mixed extends mixin(Base) {}
console.log(new Mixed(5).mixed(), (new Mixed(5) as Base).x);

class Secret {
  #value = 1;
  #read(): number {
    return this.#value;
  }
  get #tenfold(): number {
    return this.#value * 10;
  }
  set #tenfold(next: number) {
    this.#value = next;
  }
  run(): number[] {
    this.#tenfold = 5;
    return [this.#read(), this.#tenfold];
  }
  static #shared = 42;
  static shared(): number {
    return Secret.#shared;
  }
}
console.log(new Secret().run(), Secret.shared(), Object.keys(new Secret()));

class Store {
  set value(next: number) {
    (this as any).stored = "set " + next;
  }
}
class SubStore extends Store {
  write(): string {
    super.value = 3;
    return (this as any).stored;
  }
}
console.log(new SubStore().write());

const proto = {
  hi(): string {
    return "proto hi";
  },
};
const literal = {
  __proto__: proto,
  hi(): string {
    return "own > " + super.hi();
  },
};
console.log(literal.hi());
console.log(
  Object.getOwnPropertyNames(
    class {
      static a() {}
      static b = 1;
    },
  ),
);

class Even {
  static [Symbol.hasInstance](value: unknown): boolean {
    return typeof value === "number" && value % 2 === 0;
  }
}
console.log(2 instanceof (Even as any), 3 instanceof (Even as any));
