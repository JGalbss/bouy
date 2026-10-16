// performance.now() is a number of milliseconds since the program started. It never
// decreases, and it has a finer resolution than a millisecond.
function main(): void {
  const first = performance.now();
  let last = first;
  let monotonic = true;
  let fine = false;
  for (let i = 0; i < 2000; i++) {
    const now = performance.now();
    if (now < last) monotonic = false;
    if (!Number.isInteger(now)) fine = true;
    last = now;
  }
  console.log(typeof first, Number.isFinite(first), first >= 0);
  console.log(`never decreases: ${monotonic}`);
  console.log(`finer than a millisecond: ${fine}`);
}

main();
