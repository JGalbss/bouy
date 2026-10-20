// A long loop collects its own garbage inside the job (contract section 17.2). Each loop
// below allocates more than the collector's threshold, and what it keeps must stay intact.

class Link {
  value: number;
  next: Link | null;

  constructor(value: number, next: Link | null) {
    this.value = value;
    this.next = next;
  }
}

// A list that the loop carries in a variable.
let list: Link | null = null;
for (let i = 0; i < 30000; i++) {
  const garbage = { i, tag: `x${i}` };
  if (garbage.i % 1000 === 0) list = new Link(i, list);
}
let count = 0;
let sum = 0;
for (let node = list; node !== null; node = node.next) {
  count++;
  sum += node.value;
}
console.log("carried", count, sum);

// A promise reaction that the loop queued holds a young object until the job ends.
for (let i = 0; i < 60000; i++) {
  const o = { i };
  if (i === 100) void Promise.resolve(o).then((value) => console.log("queued", value.i));
}

// Objects stored into an object made before the loop.
const holder: Record<string, { n: number }> = {};
for (let i = 0; i < 30000; i++) {
  const o = { n: i };
  if (i % 3500 === 0) holder[`k${i}`] = o;
}
console.log("holder", JSON.stringify(holder));

// Closures that capture young objects, kept in an array made before the loop.
const reads: Array<() => number> = [];
for (let i = 0; i < 30000; i++) {
  const box = { v: i * 2 };
  if (i % 7500 === 0) reads.push(() => box.v);
}
console.log("closures", reads.map((read) => read()).join(","));

// Object keys of a Map and members of a Set.
const map = new Map<{ i: number }, number>();
const set = new Set<{ i: number }>();
for (let i = 0; i < 60000; i++) {
  const key = { i };
  if (i % 10000 === 0) {
    map.set(key, i);
    set.add(key);
  }
}
let matched = 0;
for (const [key, value] of map) if (set.has(key) && key.i === value) matched++;
console.log("map", map.size, matched);

// A WeakRef keeps its target until the job ends.
const refs: WeakRef<{ i: number }>[] = [];
for (let i = 0; i < 60000; i++) {
  const target = { i };
  if (i % 20000 === 0) refs.push(new WeakRef(target));
}
console.log("weak", refs.map((ref) => ref.deref()?.i).join(","));

// A variable that the loop assigns, and a captured variable that it writes.
let last: { i: number } | undefined;
let captured = { i: -1 };
const readCaptured = () => captured.i;
let w = 0;
while (w < 60000) {
  last = { i: w };
  if (w === 59999) captured = { i: w };
  w++;
}
console.log("last", last?.i, readCaptured());

// Nested loops, a labeled continue, try/finally, and for...of over a generator.
function* numbers(n: number): Generator<{ i: number }> {
  for (let i = 0; i < n; i++) yield { i };
}
let total = 0;
let finallies = 0;
outer: for (let a = 0; a < 30; a++) {
  for (const item of numbers(2000)) {
    try {
      if (item.i === 1999) continue outer;
      const pair = [item.i, item.i + 1];
      total += pair[1] - pair[0];
    } finally {
      finallies++;
    }
  }
}
console.log("nested", total, finallies);

// Loops inside callbacks of a built-in, which holds the earlier results.
const made = Array.from({ length: 4 }, (_, k) => {
  const kept = { k, picks: [] as number[] };
  let i = 0;
  do {
    const tmp = { i };
    if (tmp.i % 6000 === 0) kept.picks.push(tmp.i);
    i++;
  } while (i < 30000);
  return kept;
});
console.log("callbacks", JSON.stringify(made));

// for...in over objects made in the loop, and an async function whose loop awaits.
const keys: string[] = [];
for (let i = 0; i < 30000; i++) {
  const o: Record<string, number> = { [`a${i % 3}`]: i, b: 1 };
  for (const key in o) if (i >= 29997) keys.push(key);
}
console.log("for-in", keys.join(","));

async function gather(): Promise<number> {
  const kept: { i: number }[] = [];
  for (let i = 0; i < 30000; i++) {
    const o = { i };
    if (i % 5000 === 0) {
      await null;
      kept.push(o);
    }
  }
  return kept.reduce((acc, o) => acc + o.i, 0);
}
gather().then((value) => console.log("async", value));
