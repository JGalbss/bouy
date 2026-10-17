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
