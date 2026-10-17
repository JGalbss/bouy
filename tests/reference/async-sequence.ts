// Async loops: sequential awaits accumulate into loop variables.
const delay = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
async function fetchValue(n: number): Promise<number> {
  await delay(n % 3);
  return n * n;
}

async function sumSequential(items: number[]): Promise<number> {
  let sum = 0;
  for (const item of items) {
    sum += await fetchValue(item);
  }
  return sum;
}

async function countdown(from: number): Promise<string[]> {
  const out: string[] = [];
  let n = from;
  while (n > 0) {
    await delay(1);
    out.push(String(n));
    n--;
  }
  return out;
}

async function main() {
  console.log(await sumSequential([1, 2, 3, 4]));
  console.log((await countdown(3)).join(" "));
  const all = await Promise.all([1, 2, 3].map(async (n) => (await fetchValue(n)) + 1));
  console.log(all);
  let i = 0;
  for (; i < 3; i++) {
    if (i === 1) continue;
    await delay(1);
  }
  console.log("i", i);
}
main().then(() => console.log("done"));
