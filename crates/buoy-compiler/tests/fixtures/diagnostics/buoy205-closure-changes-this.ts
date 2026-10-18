export class Tally {
  #count = 0;
  addAll(items: number[]): number {
    items.forEach((item) => {
      this.#count += item;
    });
    return this.#count;
  }
}
