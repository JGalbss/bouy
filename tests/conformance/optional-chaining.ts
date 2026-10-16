interface User {
  name: string;
  address?: { city?: string; zip?: string };
  tags?: string[];
  greet?: () => string;
}

function city(user: User | null | undefined): string {
  return user?.address?.city ?? "unknown";
}

function main(): void {
  const full: User = { name: "Ann", address: { city: "Oslo" }, tags: ["a"], greet: () => "hi" };
  const bare: User = { name: "Bob" };
  console.log(city(full), city(bare), city(null), city(undefined));
  console.log(full.tags?.length, bare.tags?.length);
  console.log(full.greet?.(), bare.greet?.());
  console.log(full.tags?.[0], bare.tags?.[0]);
  const zero = 0;
  const empty = "";
  console.log(zero ?? 5, empty ?? "fallback", null ?? "n", undefined ?? "u");
  console.log(zero || 5, empty || "fallback", zero && "never", 1 && "yes");
  let maybe: string | undefined;
  maybe ??= "assigned";
  maybe ??= "ignored";
  console.log(maybe);
  let count = 0;
  count ||= 10;
  console.log(count);
  let flag = true;
  flag &&= false;
  console.log(flag);
  const deep = { a: { b: { c: [1, 2, 3] } } };
  console.log(deep?.a?.b?.c?.length, deep.a?.b?.c?.[1]);
}

main();
