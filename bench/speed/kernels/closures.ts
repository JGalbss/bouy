// Closures: array methods with closures over 100,000 order records: filter, map, reduce,
// some, a sort with a comparator, a group-by reduce into an array, and a chain of curried
// adders. One iteration does it `size` times. Usage: closures.ts [warmup] [runs] [size]

type Status = "open" | "paid" | "void";

interface Order {
  id: number;
  customer: number;
  amount: number;
  status: Status;
  items: number;
}

const STATUSES: Status[] = ["open", "paid", "void"];
const CUSTOMERS = 997;

const orders: Order[] = Array.from({ length: 100000 }, (_, i) => ({
  id: i,
  customer: i % CUSTOMERS,
  amount: ((i * 31) % 10000) / 100,
  status: STATUSES[i % 3] ?? "open",
  items: 1 + (i % 5),
}));

const makeAdder =
  (k: number) =>
  (x: number): number =>
    x + k;

function scan(): number {
  const paid = orders.filter((o) => o.status === "paid");
  const totals = paid.map((o) => o.amount * o.items);
  const revenue = totals.reduce((sum, t) => sum + t, 0);
  const bigCustomers = orders.filter((o) => o.amount > 50).map((o) => o.customer);
  const anyVoidBig = orders.some((o) => o.status === "void" && o.amount > 99.9);
  const top = paid
    .slice()
    .sort((a, b) => b.amount - a.amount || a.id - b.id)
    .slice(0, 10)
    .map((o) => o.id);
  const byCustomer = orders.reduce((acc: number[], o) => {
    acc[o.customer] = (acc[o.customer] ?? 0) + o.amount;
    return acc;
  }, new Array<number>(CUSTOMERS).fill(0));
  const adders = [1, 2, 3].map(makeAdder);
  const adjusted = totals.map((t) => adders.reduce((v, add) => add(v), t));
  const best = byCustomer.reduce((max, v) => (v > max ? v : max), 0);
  return (
    Math.round(revenue) +
    bigCustomers.length +
    (anyVoidBig ? 1 : 0) +
    top.reduce((s, id) => s + id, 0) +
    Math.round(best) +
    Math.round(adjusted.reduce((s, v) => s + v, 0))
  );
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

bench("closures", 1, iteration);
