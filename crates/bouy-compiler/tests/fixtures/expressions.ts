export function operators(a: number, b: number, s: string): unknown[] {
  return [
    a + b,
    a - b,
    a * b,
    a / b,
    a % b,
    a ** b,
    -a,
    +s,
    a & b,
    a | b,
    a ^ b,
    ~a,
    a << b,
    a >> b,
    a >>> b,
  ];
}

export function comparisons(a: unknown, b: unknown): boolean[] {
  return [
    a === b,
    a !== b,
    a == b,
    a != b,
    (a as number) < (b as number),
    !a,
    typeof a === "string",
  ];
}

export function logical(a: unknown, b: unknown): unknown[] {
  return [a && b, a || b, a ?? b, a ? 1 : 2, "k" in (b as object), a instanceof Error];
}

export function literals(name: string): unknown {
  const list = [1, 2.5, "three", true, null, undefined];
  const spread = [0, ...list];
  const object = { name, nested: { deep: [1] }, "quoted-key": 1 };
  const merged = { ...object, extra: name };
  const computed = { [name]: 1 };
  return [`hello ${name}!`, list, spread, merged, computed, `plain`];
}

export function optional(
  user: { address?: { city?: string }; greet?: () => string } | null,
): unknown {
  return [user?.address?.city, user?.greet?.(), user?.address?.["city"] ?? "none"];
}

export function destructure(input: {
  a: number;
  b?: number[];
  rest1: number;
  rest2: number;
}): unknown {
  const { a, b: [first] = [], ...others } = input;
  const [x, , y = 3, ...tail] = [1, 2];
  return [a, first, others, x, y, tail];
}
