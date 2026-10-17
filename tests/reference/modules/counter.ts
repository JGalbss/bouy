export let count = 0;
export function increment(): number {
  count += 1;
  return count;
}
export const label = "counter";
export default class Counter {
  static created = 0;
  constructor() {
    Counter.created += 1;
  }
}
