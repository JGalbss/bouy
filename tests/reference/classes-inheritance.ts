// Classes with inheritance, super calls, and method overrides.
class Animal {
  name: string;
  constructor(name: string) {
    this.name = name;
  }
  speak(): string {
    return `${this.name} makes a sound`;
  }
  describe(): string {
    return `[${this.speak()}]`;
  }
}

class Dog extends Animal {
  tricks: string[] = [];
  constructor(name: string) {
    super(name);
    this.tricks.push("sit");
  }
  speak(): string {
    return `${super.speak()} and barks`;
  }
}

class Puppy extends Dog {
  speak(): string {
    return super.speak() + " softly";
  }
}

const d = new Dog("Rex");
const p = new Puppy("Bit");
console.log(d.describe());
console.log(p.describe(), p.tricks);
console.log(p instanceof Puppy, p instanceof Dog, p instanceof Animal, d instanceof Puppy);
console.log(Object.getPrototypeOf(p) === Puppy.prototype, p.constructor === Puppy);

// extends checks IsConstructor before it reads prototype, and a Proxy of a class
// is a constructor.
const arrow = (): void => {};
Object.defineProperty(arrow, "prototype", {
  get() {
    throw new Error("prototype was read");
  },
});
for (const parent of [arrow, async function () {}, new Proxy(() => {}, {})]) {
  try {
    class Broken extends (parent as unknown as new () => object) {}
    console.log("extended", Broken.name);
  } catch (error) {
    console.log((error as Error).constructor.name);
  }
}
class Base {
  kind = "base";
}
const Wrapped = new Proxy(Base, {});
class FromProxy extends Wrapped {}
console.log(new FromProxy().kind, new FromProxy() instanceof Base);
