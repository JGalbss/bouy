type Node =
  | { kind: "num"; value: number }
  | { kind: "bin"; op: string; left: Node; right: Node }
  | { kind: "neg"; operand: Node };

type Parsed = { node: Node; pos: number };

function parse(source: string): Node {
  const chars = source.split("").filter((ch) => ch !== " ");
  const result = expression(chars, 0);
  if (result.pos !== chars.length) throw new Error("trailing input at " + result.pos);
  return result.node;
}

function expression(chars: string[], start: number): Parsed {
  let { node, pos } = term(chars, start);
  while (pos < chars.length && (chars[pos] === "+" || chars[pos] === "-")) {
    const op = chars[pos];
    const right = term(chars, pos + 1);
    node = { kind: "bin", op, left: node, right: right.node };
    pos = right.pos;
  }
  return { node, pos };
}

function term(chars: string[], start: number): Parsed {
  let { node, pos } = factor(chars, start);
  while (pos < chars.length && (chars[pos] === "*" || chars[pos] === "/")) {
    const op = chars[pos];
    const right = factor(chars, pos + 1);
    node = { kind: "bin", op, left: node, right: right.node };
    pos = right.pos;
  }
  return { node, pos };
}

function factor(chars: string[], start: number): Parsed {
  const ch = chars[start];
  if (ch === "-") {
    const inner = factor(chars, start + 1);
    return { node: { kind: "neg", operand: inner.node }, pos: inner.pos };
  }
  if (ch === "(") {
    const inner = expression(chars, start + 1);
    if (chars[inner.pos] !== ")") throw new Error("expected )");
    return { node: inner.node, pos: inner.pos + 1 };
  }
  let pos = start;
  let digits = "";
  while (pos < chars.length && chars[pos] >= "0" && chars[pos] <= "9") {
    digits += chars[pos];
    pos++;
  }
  if (digits === "") throw new Error("expected a number at " + pos);
  return { node: { kind: "num", value: Number(digits) }, pos };
}

function evaluate(node: Node): number {
  switch (node.kind) {
    case "num":
      return node.value;
    case "neg":
      return -evaluate(node.operand);
    case "bin": {
      const a = evaluate(node.left);
      const b = evaluate(node.right);
      if (node.op === "+") return a + b;
      if (node.op === "-") return a - b;
      if (node.op === "*") return a * b;
      return a / b;
    }
  }
}

function show(node: Node): string {
  if (node.kind === "num") return String(node.value);
  if (node.kind === "neg") return `(-${show(node.operand)})`;
  return `(${show(node.left)} ${node.op} ${show(node.right)})`;
}

function main(): void {
  for (const source of ["1 + 2 * 3", "(1 + 2) * 3", "-4 + 10 / 4", "2 * (3 + (4 - 1)) * -1"]) {
    const tree = parse(source);
    console.log(show(tree), "=", evaluate(tree));
  }
  for (const bad of ["1+", "(1", "1 2"]) {
    try {
      parse(bad);
    } catch (e) {
      console.log("error:", (e as Error).message);
    }
  }
}

main();
