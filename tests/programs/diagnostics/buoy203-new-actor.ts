class Counter {
  #count = 0;

  increment(): number {
    this.#count++;
    return this.#count;
  }
}

const counter = new Counter();
console.log(counter.increment());
