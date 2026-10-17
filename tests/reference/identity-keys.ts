// Objects as Map keys and in Sets compare by identity, not by shape.
const k1 = { id: 1 };
const k2 = { id: 1 };
const m = new Map<object, string>();
m.set(k1, "first");
m.set(k2, "second");
console.log(m.size, m.get(k1), m.get(k2), m.get({ id: 1 }));
console.log(k1 === k2, k1 === k1, k1 == k2);

const seen = new Set<object>();
seen.add(k1);
seen.add(k1);
seen.add(k2);
console.log(seen.size, seen.has(k2), seen.has({ id: 1 }));

const weak = new WeakMap<object, number>();
weak.set(k1, 42);
console.log(weak.get(k1), weak.has(k2));

k1.id = 7;
console.log(
  m.get(k1),
  [...m.keys()].map((k) => (k as { id: number }).id),
);
