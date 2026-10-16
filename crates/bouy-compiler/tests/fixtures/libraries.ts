import { sleep } from "bouy";

export async function globals(text: string): Promise<unknown[]> {
  console.log(Math.max(1, 2), Math.PI, JSON.stringify({ a: 1 }));
  const parsed = parseInt(text, 10);
  await sleep(1);
  const all = await Promise.all([Promise.resolve(1), Promise.resolve(2)]);
  const mapped = await Promise.all([1, 2].map(async (x) => x * 2));
  const settled = await Promise.allSettled([1, 2].map(async (x) => x * 2));
  const first = await Promise.race([1, 2].map(async (x) => x));
  return [
    parsed,
    isNaN(parsed),
    String(parsed),
    Number(text),
    Boolean(text),
    [1, 2].map(String),
    process.env.HOME,
    process.argv,
    Object.keys({ a: 1 }),
    new Map(),
    new Error("e"),
    all,
    mapped,
    settled,
    first,
  ];
}
