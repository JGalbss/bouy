export function chains(groups: Map<string, string[]>, word: string): number {
  const counts = new Map<string, number>();
  counts.set("a", 1).set("b", 2);
  groups.get(word[0])!.push(word);
  groups.get(word)?.push(word);
  const buckets: Record<string, number[]> = {};
  (buckets[word] ??= []).push(1);
  const target = { a: 1 };
  Object.assign(target, { b: 2 });
  const ys = [1];
  ys["push"](2);
  return counts.size + ys.length + target.a;
}

export function orphaned(): number {
  let o = { k: 1 };
  o.k = ((o = { k: 100 }), 5);
  return o.k;
}

export function caught(tokens: string[]): number {
  let pos = 0;
  let sum = 0;
  try {
    while (pos < tokens.length) sum += JSON.parse(tokens[pos++]);
  } catch {
    return pos;
  }
  return sum;
}
