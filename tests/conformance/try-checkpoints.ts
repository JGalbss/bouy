// `catch` and `finally` see every rebinding the `try` body made before it threw or jumped:
// loop headers, `if` tests and `switch` discriminants with an early exit, and a rebinding
// earlier in the statement that throws.

function firstNegative(xs: number[]): number {
  let i = 0;
  let closed = false;
  try {
    for (; i < xs.length; i++) {
      if (xs[i] === 0) return -1;
      if (xs[i] < 0) break;
    }
  } finally {
    closed = true;
  }
  return closed ? i : -2;
}

function failedItem(items: string[]): number {
  let index = 0;
  try {
    for (; index < items.length; index++) {
      JSON.parse(items[index]);
    }
  } catch {
    return index;
  }
  return -1;
}

function badLine(lines: string[]): string {
  let line: string | undefined;
  try {
    while ((line = lines.shift()) !== undefined) JSON.parse(line);
  } catch {
    return `bad line ${line}, ${lines.length} left`;
  }
  return "all good";
}

function failedOn(texts: string[]): string {
  let current = "none";
  try {
    for (current of texts) JSON.parse(current);
  } catch {
    return current;
  }
  return "none failed";
}

function scannedUpTo(xs: number[], target: number): string {
  let i = 0;
  let seen = -1;
  try {
    for (; i < xs.length; i++) {
      if (xs[i] === target) return `found at ${i}`;
    }
    return "missing";
  } finally {
    seen = i;
    console.log("scanned up to", seen);
  }
}

function ifTest(xs: string[]): string {
  let i = 0;
  try {
    if (xs[i++] === "stop") return "stopped";
    JSON.parse(xs[i]);
  } catch {
    return `caught at i=${i}`;
  }
  return "ok";
}

function ifTestFinally(): string {
  let i = 0;
  let log = "";
  try {
    if (i++ > 5) return "big";
  } finally {
    log += "f";
  }
  return `i=${i} ${log}`;
}

function switchDiscriminant(commands: string[]): string {
  let pos = 0;
  let cleaned = false;
  try {
    switch (commands[pos++]) {
      case "quit":
        return "quit";
      default:
        break;
    }
  } finally {
    cleaned = true;
  }
  return `pos=${pos} ${cleaned}`;
}

function midStatement(tokens: string[]): string {
  let pos = 0;
  let sum = 0;
  try {
    while (pos < tokens.length) {
      sum += JSON.parse(tokens[pos++]);
    }
  } catch {
    return `error after token ${pos}, sum ${sum}`;
  }
  return `sum ${sum}`;
}

function sequence(): number {
  let x = 0;
  try {
    (x++, JSON.parse("{"));
  } catch {
    return x;
  }
  return -1;
}

console.log(firstNegative([4, 5, -6, 7]), firstNegative([1, 0]));
console.log(failedItem(["1", "2", "oops", "4"]));
console.log(badLine(["1", "2", "x", "4"]));
console.log(failedOn(["1", "2", "x"]));
console.log(scannedUpTo([5, 6, 7, 8], 7));
console.log(ifTest(["go", "{"]), ifTestFinally());
console.log(switchDiscriminant(["go"]), switchDiscriminant(["quit"]));
console.log(midStatement(["1", "2", "x", "4"]), sequence());
