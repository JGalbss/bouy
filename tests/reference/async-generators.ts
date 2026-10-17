// Async functions and async generators: try/finally around await, for await over async
// and sync iterables, early exit, return(), and yield* to another async generator.
async function settle(): Promise<string> {
  try {
    await Promise.reject(new Error("rejected"));
  } catch (error) {
    console.log("caught", (error as Error).message);
  } finally {
    console.log("finally after await");
  }
  return "settled";
}

async function* numbers() {
  try {
    yield 1;
    yield await Promise.resolve(2);
  } finally {
    console.log("numbers finally");
  }
}

async function* delegate() {
  yield* numbers();
  yield* [10, 11];
}

async function main(): Promise<void> {
  console.log(await settle());
  for await (const n of numbers()) console.log("numbers", n);
  for await (const v of [Promise.resolve("p1"), "p2"]) console.log("sync iterable", v);
  const it = numbers();
  console.log(await it.next());
  console.log(await it.return(0));
  console.log(await it.next());
  for await (const n of numbers()) {
    console.log("break at", n);
    break;
  }
  for await (const n of delegate()) console.log("delegate", n);
  const [first = await Promise.resolve(7)] = [];
  console.log("await in a default", first);
  try {
    try {
      await null;
    } catch {
      console.log("not reached");
    }
    throw new Error("thrown after an inner try");
  } catch (error) {
    console.log("outer catch", (error as Error).message);
  }
}

async function placements(n: number): Promise<unknown[]> {
  const out: unknown[] = [];
  switch (n) {
    case await Promise.resolve(1):
      out.push("case one");
      break;
    default:
      out.push("default");
  }
  const maybe: Record<string, number> | null = n === 1 ? { k: 7 } : null;
  out.push(maybe?.[await Promise.resolve("k")]);
  let i = 0;
  do {
    i++;
  } while (await Promise.resolve(i < 3));
  out.push(i, (await Promise.resolve(null)) ?? "nullish", n ? await Promise.resolve("yes") : "no");
  return out;
}

main().then(async () => {
  console.log(await placements(1), await placements(0));
});
