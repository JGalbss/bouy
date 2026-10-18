export function writes(
  input: { count: number; tags: string[]; nested: { a: { b: number } } },
  key: string,
) {
  const data = input;
  data.count = 1;
  data.count += 2;
  data.count++;
  data.nested.a.b *= 3;
  data.tags.push("x");
  data.tags[0] = key;
  delete data.nested.a;
  const items = [3, 1, 2];
  items.sort((a, b) => a - b);
  const last = items.pop();
  const copy = [...items].reverse();
  return [data, items, last, copy];
}

export function maps(): unknown {
  const seen = new Map<string, number>();
  seen.set("a", 1);
  const set = new Set<number>();
  set.add(1);
  set.delete(1);
  return [seen, set];
}
