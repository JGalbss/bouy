// Regex: run four regular expressions over 10,000 generated log lines of about 1 MB: a
// global match of email addresses, matchAll with capture groups, a test on each line, and
// a global replace. One iteration does it `size` times. Usage: regex.ts [warmup] [runs] [size]

const LEVELS = ["INFO", "WARN", "ERROR", "DEBUG"];
const STATUSES = [200, 201, 404, 500];

function pad(n: number): string {
  return n < 10 ? `0${n}` : `${n}`;
}

function line(i: number): string {
  const time = `2026-10-${pad((i % 28) + 1)}T${pad(i % 24)}:${pad(i % 60)}:${pad((i * 7) % 60)}Z`;
  const ip = `10.${i % 256}.${(i >> 8) % 256}.${i % 7}`;
  return `${time} ${LEVELS[i % 4]} user=user${i}@example.com ip=${ip} path=/api/v1/items/${i % 1000} status=${STATUSES[i % 4]} ms=${i % 250}`;
}

const text = Array.from({ length: 10000 }, (_, i) => line(i)).join("\n");

function scan(): number {
  let check = 0;
  check += (text.match(/[\w.+-]+@[\w-]+\.[\w.]+/g) ?? []).length;
  for (const match of text.matchAll(/(\d{4})-(\d{2})-(\d{2})T(\d{2}):/g)) {
    check += Number(match[3]) + Number(match[4]);
  }
  check += text.split("\n").filter((each) => /status=5\d\d/.test(each)).length;
  check += text.replace(/\d+/g, "#").length;
  return check;
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

bench("regex", 1, iteration);
