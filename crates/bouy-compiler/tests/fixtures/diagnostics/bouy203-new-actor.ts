class Counter {
  #count = 0;
  increment(): number {
    return ++this.#count;
  }
}

const counter = new Counter();
console.log(counter);
