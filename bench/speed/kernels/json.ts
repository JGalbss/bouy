// JSON: parse and stringify a document of about 1 MB, an array of user records with
// strings, numbers, booleans, nested objects, and arrays. One iteration parses the text
// and stringifies the result `size` times. Usage: json.ts [warmup] [runs] [size]

interface Payment {
  at: number;
  amount: number;
  currency: string;
}

interface User {
  id: number;
  name: string;
  email: string;
  active: boolean;
  score: number;
  tags: string[];
  address: { street: string; city: string; zip: string };
  history: Payment[];
}

const TAGS = ["alpha", "beta", "gamma", "delta", "epsilon", "zeta"];

function user(i: number): User {
  return {
    id: i,
    name: `User ${i}`,
    email: `user${i}@example.com`,
    active: i % 3 === 0,
    score: ((i * 37) % 1000) / 8,
    tags: TAGS.filter((_, index) => (i + index) % 3 === 0),
    address: { street: `${i} Main Street`, city: "Springfield", zip: `${10000 + i}` },
    history: [0, 1, 2].map((k) => ({
      at: 1700000000 + i * 60 + k,
      amount: ((i + k) % 100) / 4,
      currency: "USD",
    })),
  };
}

const document = JSON.stringify(Array.from({ length: 2900 }, (_, i) => user(i)));

function iteration(size: number): number {
  let check = 0;
  for (let i = 0; i < size; i++) {
    const value: User[] = JSON.parse(document);
    const text = JSON.stringify(value);
    if (text.length !== document.length) throw new Error("json: round trip changed the text");
    check += text.length + value.length;
  }
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

bench("json", 4, iteration);
