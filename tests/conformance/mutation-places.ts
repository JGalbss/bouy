// Mutations that reach a place through a chain: mutators that return their receiver, Map
// entries, logical assignments, `Object.assign`, computed method names, optional calls,
// and a right side that assigns the root variable.

function chains(): void {
  const m = new Map<string, number>();
  m.set("a", 1).set("b", 2);
  const s = new Set<number>();
  s.add(1).add(2).add(3);
  const xs = [3, 1, 2];
  xs.sort().reverse();
  const initial = new Map<string, number>().set("x", 1).set("y", 2);
  console.log(m.size, s.size, JSON.stringify(xs), initial.size);
}

function mapEntries(): void {
  const groups = new Map<string, string[]>();
  for (const word of ["ant", "ape", "bee"]) {
    if (!groups.has(word[0])) groups.set(word[0], []);
    groups.get(word[0])!.push(word);
  }
  const counts = new Map<string, { n: number }>([["a", { n: 0 }]]);
  counts.get("a")!.n++;
  counts.get("a")!.n += 10;
  console.log(JSON.stringify([...groups.values()]), counts.get("a")!.n);
}

function logicalAssignments(): void {
  const groups: Record<string, number[]> = {};
  for (const n of [1, 2, 3, 4, 5]) (groups[n % 2 ? "odd" : "even"] ??= []).push(n);
  const lists: Record<string, string[]> = {};
  for (const word of ["x", "y", "x"]) (lists[word] ||= []).push(word);
  let hits = 0;
  let cache: string | undefined;
  cache ??= (hits++, "filled");
  cache ??= (hits++, "again");
  let empty = "";
  empty ||= (hits++, "set");
  console.log(
    JSON.stringify(groups.odd),
    JSON.stringify(groups.even),
    lists.x.length,
    cache,
    empty,
    hits,
  );
}

function objectAssign(): void {
  const target = { a: 1 };
  Object.assign(target, { b: 2 }, { c: 3 });
  const options: { retries?: number } = {};
  Object.assign(options, { retries: 3 });
  const merged = Object.assign({}, target, { d: 4 });
  console.log(JSON.stringify(target), options.retries, JSON.stringify(merged));
}

function computedNames(): void {
  const ys = [1];
  ys["push"](2);
  const handlers = [(k: number): number => k * 2, (k: number): number => k + 1];
  const named: Record<string, (k: number) => number> = { inc: (k) => k + 1 };
  console.log(JSON.stringify(ys), handlers[0](5), handlers[1](5), named["inc"](5));
}

function optionalCalls(): void {
  const list: number[] | undefined = [];
  list?.push(1);
  const missing: number[] | undefined = undefined;
  const pushed = missing?.push(1);
  const groups = new Map<string, number[]>([["a", []]]);
  groups.get("a")?.push(7);
  groups.get("b")?.push(8);
  console.log(JSON.stringify(list), pushed, JSON.stringify(groups.get("a")), groups.has("b"));
}

function rootReassigned(): void {
  let o = { k: 1 };
  o.k = ((o = { k: 100 }), 5);
  let arr: number[] = [1, 2];
  arr.push(((arr = [9]), 3));
  let p = { k: 1 };
  p.k += (p = { k: 100 }).k;
  let q = [1, 2, 3];
  q[0] += (q = [50, 60])[1];
  const r = { j: 0, k: 1 };
  r.k = ((r.j = 3), 5);
  const s = { j: 0, k: 1 };
  s.k += ((s.j = 4), 5);
  console.log(
    o.k,
    JSON.stringify(arr),
    p.k,
    JSON.stringify(q),
    JSON.stringify(r),
    JSON.stringify(s),
  );
}

function inOrder(): void {
  const log = <T>(label: string, value: T): T => {
    console.log(label);
    return value;
  };
  console.log(log("left", "a") in log("right", { a: 1 }));
}

function numericKeys(): void {
  const o: Record<string, string> = { 1e21: "big", 1e-7: "small", 0.5: "half" };
  const k = 1e21;
  const p = { [k]: 1, [1e21]: 2 };
  console.log(Object.keys(o).sort().join(","), o[1e21], o[1e-7], o[0.5], Object.keys(p).length);
}

chains();
mapEntries();
logicalAssignments();
objectAssign();
computedNames();
optionalCalls();
rootReassigned();
inOrder();
numericKeys();
