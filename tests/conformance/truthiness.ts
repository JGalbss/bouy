function truthy(value: unknown): string {
  return value ? "truthy" : "falsy";
}

function main(): void {
  const values: unknown[] = [
    0,
    1,
    -1,
    "",
    "0",
    " ",
    null,
    undefined,
    NaN,
    [],
    {},
    true,
    false,
    0.0001,
  ];
  console.log(values.map(truthy).join(","));
  let n = 3;
  const seen: number[] = [];
  while (n) {
    seen.push(n);
    n--;
  }
  console.log(seen.join(","));
  const name = "";
  console.log(name || "anonymous", name && "never", !name, !!name);
  if (!undefined && !null) console.log("both falsy");
  const list: number[] = [];
  console.log(list.length ? "non-empty" : "empty");
}

main();
