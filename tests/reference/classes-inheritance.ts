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

// A base method reads the fields of a subclass instance, whose own keys start with the
// keys of the base class; a method borrowed by an object of another class still reads
// that object's own keys.
class Point {
  x: number;
  y: number;
  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
  norm(): number {
    return this.x * this.x + this.y * this.y;
  }
  shift(dx: number): this {
    this.x += dx;
    return this;
  }
}

class Point3 extends Point {
  z = 0;
  label: string;
  constructor(x: number, y: number, z: number) {
    super(x, y);
    this.z = z;
    this.label = `p${z}`;
  }
  norm(): number {
    return super.norm() + this.z * this.z;
  }
}

class Pair {
  y = 5;
  x = 6;
}

const points: Point[] = [new Point(1, 2), new Point3(1, 2, 3), new Point(3, 4).shift(1)];
console.log(points.map((point) => point.norm()), Object.keys(points[1]));
console.log(Point.prototype.norm.call(new Pair()), Point.prototype.shift.call(new Pair(), 1));
const moved = new Point(1, 1);
delete (moved as { y?: number }).y;
(moved as { y?: number }).y = 7;
(moved as unknown as { extra: boolean }).extra = true;
console.log(moved.norm(), moved.shift(2).x, Object.keys(moved));
const odd = new Point(0, 0);
Object.defineProperty(odd, "x", { get: () => 9 });
console.log(odd.norm(), Object.keys(odd));
