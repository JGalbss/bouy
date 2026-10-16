type Token = { kind: "number" | "ident" | "op" | "paren"; text: string };

function isDigit(ch: string): boolean {
  return ch >= "0" && ch <= "9";
}

function isLetter(ch: string): boolean {
  return (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || ch === "_";
}

function tokenize(source: string): Token[] {
  const tokens: Token[] = [];
  let i = 0;
  while (i < source.length) {
    const ch = source[i];
    if (ch === " ") {
      i++;
      continue;
    }
    if (isDigit(ch)) {
      let text = "";
      while (i < source.length && (isDigit(source[i]) || source[i] === ".")) {
        text += source[i];
        i++;
      }
      tokens.push({ kind: "number", text });
      continue;
    }
    if (isLetter(ch)) {
      const start = i;
      while (i < source.length && (isLetter(source[i]) || isDigit(source[i]))) {
        i++;
      }
      tokens.push({ kind: "ident", text: source.slice(start, i) });
      continue;
    }
    if (ch === "(" || ch === ")") {
      tokens.push({ kind: "paren", text: ch });
    } else if ("+-*/%".includes(ch)) {
      tokens.push({ kind: "op", text: ch });
    } else {
      throw new Error(`unexpected character ${ch} at ${i}`);
    }
    i++;
  }
  return tokens;
}

function main(): void {
  const tokens = tokenize("price * (qty + 2.5) - discount_1 % 3");
  console.log(tokens.length);
  console.log(tokens.map((t) => `${t.kind}:${t.text}`).join(" "));
  try {
    tokenize("1 + $");
  } catch (e) {
    console.log((e as Error).message);
  }
}

main();
