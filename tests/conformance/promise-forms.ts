// Promise.all, allSettled, race, and any over items.map(f) call f as map
// calls it: with the item, the index, and the array. A namespace such as
// String works as f, and a value with its own map method keeps it.

async function main(): Promise<void> {
  const xs = [1, 2];
  console.log(await Promise.all(xs.map((x, i, all) => all.length + x + i)));
  console.log(await Promise.all(xs.map(String)));
  const box = { map: (f: (x: number) => number) => [f(1), f(2)] };
  console.log(await Promise.all(box.map((x) => x * 10)));
  const settled = await Promise.allSettled(xs.map((x, i, all) => all.length * x));
  console.log(
    settled.map((s) => s.status),
    settled.map((s) => (s.status === "fulfilled" ? s.value : 0)),
  );
  console.log(await Promise.race(xs.map((x, i, all) => all.length + x)));
  console.log(await Promise.any([Promise.reject(new Error("no")), Promise.resolve(2)]));
  console.log(
    await Promise.any(
      xs.map(async (x) => {
        if (x === 1) throw new Error("first fails");
        return x * 100;
      }),
    ),
  );
  try {
    await Promise.any(
      xs.map(async (x) => {
        throw new Error(`no ${x}`);
      }),
    );
  } catch (e) {
    const failure = e as AggregateError;
    console.log(
      failure.name,
      failure.message,
      failure.errors.map((error: Error) => error.message),
    );
  }
}

await main();
