// Strings: build a CSV text of 100,000 rows with template literals and `+=`, split it into
// lines and fields, parse numbers, search, slice, upper-case, and join. One iteration does
// it `size` times. Usage: strings.ts [warmup] [runs] [size]

const ROWS = 100000;
const TAGS = ["alpha", "beta", "gamma", "delta"];

function build(): string {
  let text = "";
  for (let i = 0; i < ROWS; i++) {
    text += `${i},item-${i},${(i * 7) % 1000},${TAGS[i % 4]}\n`;
  }
  return text;
}

function scan(text: string): number {
  let total = 0;
  const upper: string[] = [];
  for (const line of text.split("\n")) {
    if (line.length === 0) continue;
    const fields = line.split(",");
    total += Number.parseInt(fields[2] ?? "0", 10);
    if (fields[3] === "beta") upper.push((fields[1] ?? "").toUpperCase());
    const at = line.indexOf("-99");
    if (at >= 0) total += at + line.slice(at + 1, at + 3).length;
  }
  return total + upper.join(";").length;
}

function iteration(size: number): number {
  let check = 0;
  for (let i = 0; i < size; i++) {
    const text = build();
    check += text.length + scan(text);
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

bench("strings", 1, iteration);
