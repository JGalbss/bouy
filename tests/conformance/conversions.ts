// Conversions at the edges: ToPrimitive calls a user valueOf, equal numbers
// share one Map key at any size, and JSON text converts as V8 converts it.

function main(): void {
  const money = {
    cents: 150,
    valueOf(): number {
      return 150;
    },
  };
  const both = {
    toString(): string {
      return "seven";
    },
    valueOf(): number {
      return 7;
    },
  };
  const text = {
    toString(): string {
      return "T";
    },
  };
  console.log(
    "valueOf:",
    (money as any) + 1,
    (money as any) * 2,
    (money as any) > 100,
    (money as any) == 150,
  );
  console.log("both methods:", (both as any) + "", (both as any) + 1, `${both}`, String(both));
  console.log("toString only:", (text as any) + 1, `${text}`);

  console.log(
    "big keys:",
    1e20 === 10 ** 20,
    new Set([1e20, 10 ** 20]).size,
    new Map([[1e20, "x"]]).get(10 ** 20),
  );
  console.log(
    "bigger keys:",
    new Set([1e21, 10 ** 21]).size,
    [...new Set([2 ** 70, 2 ** 70 * 1.0])].length,
  );
  console.log("float keys:", new Set([1, 1.0, -0, 0]).size, new Map([[2, "two"]]).get(2.0));

  console.log(
    "parseInt zeros:",
    parseInt("ge0ifld2d0552e", 22) === parseInt("0ge0ifld2d0552e", 22),
    parseInt("000z", 36),
  );

  console.log(
    "JSON -0:",
    Object.is(JSON.parse("-0"), -0),
    1 / JSON.parse("-0e0"),
    JSON.parse("[-0.5, -0, 0]"),
  );
  console.log(
    "JSON lone surrogate:",
    JSON.parse('"\\ud800"').length,
    JSON.parse('"a\\udc00b"').length,
    JSON.parse('"\\ud83d\\ude00"') === "😀",
  );
  console.log(JSON.stringify({ a: 1 }, null, "→→→→"));
  console.log(JSON.stringify({ a: [1] }, null, "éééééééééééé"));
  console.log(JSON.stringify({ a: 1 }, null, Infinity));
  try {
    JSON.parse("é");
  } catch (e) {
    console.log((e as Error).name + ": " + (e as Error).message);
  }
  try {
    JSON.parse("€");
  } catch (e) {
    console.log((e as Error).name + ": " + (e as Error).message);
  }
  const named: any = { name: "é".repeat(60) };
  try {
    named.greet();
  } catch (e) {
    console.log(
      "message is text:",
      (e as Error).name,
      (e as Error).message.endsWith("is not a function"),
    );
  }
}

main();
