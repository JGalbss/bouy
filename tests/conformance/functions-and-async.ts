function withDefaults(
  { a, b }: { a: number; b: number } = { a: 1, b: 2 },
  ...[first = 9, ...others]: number[]
): string {
  return `${a} ${b} ${first} ${others.length}`;
}

function objectRestParam({ id, ...meta }: { id: number; [key: string]: unknown }): string {
  return `${id} ${Object.keys(meta).sort().join("+")}`;
}

async function delayedDouble(n: number): Promise<number> {
  return n * 2;
}

async function sequential(values: number[]): Promise<number> {
  let sum = 0;
  for (const value of values) {
    sum += await delayedDouble(value);
  }
  return sum;
}

function throwsInCallback(values: number[]): string {
  try {
    values.map((v) => {
      if (v > 2) throw new RangeError(`too big: ${v}`);
      return v;
    });
    return "no error";
  } catch (e) {
    return `${(e as Error).name} ${(e as Error).message}`;
  }
}

function deepSum(n: number): number {
  return n === 0 ? 0 : n + deepSum(n - 1);
}

function bigLoop(): number {
  let acc = 0;
  for (let i = 0; i < 1000000; i++) {
    acc = (acc + i * 7) % 1000003;
  }
  return acc;
}

function stringIndexing(text: string): string {
  let out = "";
  for (let i = text.length - 1; i >= 0; i--) {
    if (text[i] === " ") continue;
    out += text[i].toUpperCase();
  }
  return out;
}

function optionalCalls(
  registry: Record<string, ((n: number) => number) | undefined>,
  key: string,
  n: number,
): string {
  return String(registry[key]?.(n * 2) ?? "missing");
}

class HttpError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.name = "HttpError";
    this.status = status;
  }
}

function handle(status: number): string {
  try {
    try {
      if (status >= 400) throw new HttpError(status, `status ${status}`);
      return "ok";
    } catch (e) {
      if (e instanceof HttpError && e.status < 500) return `client ${e.status}`;
      throw e;
    }
  } catch (e) {
    return `server ${(e as HttpError).status} ${e instanceof HttpError}`;
  }
}

async function main(): Promise<void> {
  console.log(withDefaults(), "|", withDefaults({ a: 5, b: 6 }, 7, 8, 9));
  console.log(objectRestParam({ id: 1, zeta: true, alpha: 2 }));
  console.log(await sequential([1, 2, 3]));
  console.log(throwsInCallback([1, 2]), "|", throwsInCallback([1, 5]));
  console.log(deepSum(1000));
  console.log(bigLoop());
  console.log(stringIndexing("ab c d"));
  const registry = { double: (n: number) => n * 2, missing: undefined };
  console.log(
    optionalCalls(registry, "double", 5),
    optionalCalls(registry, "missing", 5),
    optionalCalls(registry, "nope", 1),
  );
  console.log(handle(200), handle(404), handle(503));
}

await main();
