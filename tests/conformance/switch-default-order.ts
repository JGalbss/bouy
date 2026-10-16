// `switch` tests its cases in source order, also the cases grouped with `default`, and takes
// `default` only when no case matches.

function classify(n: number): string {
  switch (true) {
    case n < 0:
    default:
      return "negative or other";
    case n < 10:
      return "small";
  }
}

function duplicate(x: number): string {
  switch (x) {
    case 1:
    default:
      return "first";
    case 1:
      return "second";
  }
}

function traced(v: number, label: string): number {
  console.log("eval " + label);
  return v;
}

function sideEffects(x: number): string {
  switch (x) {
    case traced(1, "a"):
      return "A";
    case traced(2, "b"):
    default:
      return "B or default";
    case traced(3, "c"):
      return "C";
  }
}

function literalDefaultFirst(word: string): string {
  let result = "";
  switch (word) {
    default:
      result = "other";
      break;
    case "a":
      result = "letter a";
      break;
  }
  return result;
}

console.log(classify(-5), classify(5), classify(50));
console.log(duplicate(1), duplicate(2));
console.log(sideEffects(3));
console.log(sideEffects(9));
console.log(sideEffects(2));
console.log(literalDefaultFirst("a"), literalDefaultFirst("b"));
