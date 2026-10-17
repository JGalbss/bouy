// Getters and setters on classes and object literals.
class Temperature {
  #celsius = 0;
  get fahrenheit(): number {
    return this.#celsius * 1.8 + 32;
  }
  set fahrenheit(value: number) {
    this.#celsius = (value - 32) / 1.8;
  }
  get celsius(): number {
    return this.#celsius;
  }
}

const t = new Temperature();
t.fahrenheit = 212;
console.log(t.celsius, t.fahrenheit);

const log: string[] = [];
const point = {
  _x: 1,
  get x() {
    log.push("get");
    return this._x;
  },
  set x(v: number) {
    log.push(`set ${v}`);
    this._x = v;
  },
};
point.x = point.x + 41;
console.log(point.x, log);
console.log(Object.keys(point));
