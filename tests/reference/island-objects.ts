// Typed code that the native tier runs, and that reads and writes values outside itself:
// module variables that hold objects and strings, and the static fields of classes. A
// run copies those objects in and writes them back, so the code around it sees each
// change, each new object, the order of its keys, and the identity of every object, as
// when the Erlang tier runs the call.

class Tag {
  static readonly FIRST = new Tag(1, "first");
  static readonly SECOND = new Tag(2, "second");

  readonly rank: number;
  readonly name: string;

  constructor(rank: number, name: string) {
    this.rank = rank;
    this.name = name;
  }
}

class Item {
  value: number;
  tag: Tag;
  label: string;
  next: Item | null = null;

  constructor(value: number, tag: Tag, label: string) {
    this.value = value;
    this.tag = tag;
    this.label = label;
  }
}

class Store {
  count = 0;
  items: Item[] = [];
  last: Item | null = null;
}

let store = new Store();
let note = "start";

function fill(n: number): number {
  for (let i = 0; i < n; i++) {
    const tag = i % 2 === 0 ? Tag.FIRST : Tag.SECOND;
    const item = new Item(i, tag, `item ${i} of ${tag.name}`);
    item.next = store.last;
    store.items.push(item);
    store.last = item;
    store.count++;
  }
  note = note + " filled " + n;
  return store.items.filter((item) => item.tag === Tag.FIRST).length;
}

function drain(n: number): number {
  let total = 0;
  for (let i = 0; i < n; i++) {
    const first = store.items.shift();
    if (first === undefined) break;
    total += first.value * first.tag.rank;
  }
  const behind = store.last?.next;
  const more = store.items.some((item) => item.value > 3) ? 1000 : 0;
  const found = store.items.findIndex((item, index) => item.value === index + 2);
  return total + more + (behind === undefined ? 100 : 10) + found * 10000;
}

function names(n: number): number {
  let length = 0;
  const parts = store.items.map((item) => item.label + "!");
  for (const part of parts) length += part.length;
  const text = `${1.5e-7} ${-0} ${2 ** 70} ${0.1 + 0.2} ${true} ${null} é☃`;
  return length + text.length * n + (text === "x" ? 1 : 0) + (note.length > 0 ? 0.5 : 0);
}

function reset(n: number): boolean {
  const old = store.last;
  store = new Store();
  store.count = n;
  if (old !== null) store.items.push(old);
  return store.items.length === 1 && store.items.includes(old) && store.last === null;
}

const before = store;
console.log(fill(5), store.count, store.items.length, note);
console.log(store === before, store.last?.label, store.last?.next?.label);
console.log(store.items[0]?.tag === Tag.FIRST, store.items[1]?.tag === Tag.SECOND);
console.log(Object.keys(store.items[0] ?? {}), JSON.stringify(store.items[1]?.tag));
console.log(drain(2), store.items.length, store.items[0]?.value);
console.log(names(2));
console.log(reset(7), store === before, store.count, before.count, before.items.length);
console.log(drain(3), fill(2), store.count, note);
// A field of another type sends the call to the Erlang tier, which gives the same result.
(store as unknown as { count: unknown }).count = "x";
console.log(fill(1), store.count);
