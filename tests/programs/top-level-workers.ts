// Promise.all at the top level stays as fast after many rounds as in the
// first: its finished workers leave no messages behind in the top-level
// process.

async function batch(): Promise<number> {
  const started = Date.now();
  for (let i = 0; i < 5000; i++) await Promise.all([i, i + 1]);
  return Date.now() - started;
}

async function main(): Promise<void> {
  const first = await batch();
  for (let k = 0; k < 4; k++) await batch();
  const last = await batch();
  console.log(
    last < 3 * first + 100
      ? "top-level Promise.all stays fast"
      : `slowed down: first ${first} ms, last ${last} ms`,
  );
}

await main();
