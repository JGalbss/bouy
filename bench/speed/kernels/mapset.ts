// MapSet: count 200,000 words drawn from 5,000 keys in a Map, track 200,000 integer keys in a
// Set with deletes, group records by id in a Map of objects, and read the insertion order of
// the keys. One iteration does it `size` times. Usage: mapset.ts [warmup] [runs] [size]

const OPERATIONS = 200000;
const WORDS = Array.from({ length: 5000 }, (_, i) => `w${i.toString(36)}`);
const MODULUS = 100003;

interface Account {
  id: number;
  total: number;
  visits: number;
}

function scan(): number {
  const counts = new Map<string, number>();
  for (let i = 0; i < OPERATIONS; i++) {
    const word = WORDS[(i * 7919) % WORDS.length] ?? "";
    counts.set(word, (counts.get(word) ?? 0) + 1);
  }

  const seen = new Set<number>();
  let duplicates = 0;
  for (let i = 0; i < OPERATIONS; i++) {
    const key = (i * 2654435761) % MODULUS;
    if (seen.has(key)) duplicates++;
    else seen.add(key);
  }
  for (let key = 0; key < MODULUS; key += 3) seen.delete(key);

  const accounts = new Map<number, Account>();
  for (let i = 0; i < OPERATIONS; i++) {
    const id = (i * 31) % 20011;
    const account = accounts.get(id);
    if (account === undefined) accounts.set(id, { id, total: i % 100, visits: 1 });
    else {
      account.total += i % 100;
      account.visits++;
    }
  }

  let sum = 0;
  for (const [, count] of counts) sum += count;
  let visits = 0;
  for (const account of accounts.values()) visits += account.visits + account.total;
  const firstKeys = [...counts.keys()].slice(0, 3).join(",");
  return sum + duplicates + seen.size + visits + firstKeys.length;
}

function iteration(size: number): number {
  let check = 0;
  for (let i = 0; i < size; i++) check += scan();
  return check;
}

function bench(name: string, defaultSize: number, work: (size: number) => number): void {
  // The reference engine has neither `process` nor `performance` yet.
  const args = typeof process === "undefined" ? [] : process.argv.slice(2).map(Number);
  const now = typeof performance === "undefined" ? Date.now : () => performance.now();
  const warmup = args[0] ?? 3;
  const runs = args[1] ?? 5;
  const size = args[2] ?? defaultSize;
  const times: number[] = [];
  let check = 0;
  for (let i = 0; i < warmup + runs; i++) {
    const start = now();
    check = work(size);
    const elapsed = now() - start;
    if (i >= warmup) times.push(elapsed);
  }
  times.sort((a, b) => a - b);
  const median = times[Math.floor(times.length / 2)] ?? 0;
  console.log(JSON.stringify({ kernel: name, size, median_ms: median, times_ms: times, check }));
}

bench("mapset", 1, iteration);
