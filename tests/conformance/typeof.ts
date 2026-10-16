function kind(value: unknown): string {
  return typeof value;
}

function main(): void {
  console.log(kind(1), kind(1.5), kind("s"), kind(true));
  console.log(kind(undefined), kind(null), kind({}), kind([]));
  console.log(
    kind(() => 1),
    kind(function named() {}),
    kind(NaN),
  );
  console.log(kind(new Map()), kind(new Set()));
  console.log(typeof undeclaredGlobalThing, typeof Math, typeof console.log);
  const values: unknown[] = [1, "two", null, [3], { four: 4 }];
  const summary = values.map((v) => (v === null ? "null" : Array.isArray(v) ? "array" : typeof v));
  console.log(summary.join(","));
}

main();
