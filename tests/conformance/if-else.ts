function grade(score: number): string {
  if (score >= 90) {
    return "A";
  } else if (score >= 80) {
    return "B";
  } else if (score >= 70) {
    return "C";
  }
  return "F";
}

function sign(n: number): string {
  if (n > 0) return "positive";
  if (n < 0) return "negative";
  return "zero";
}

function describe(value: number): string {
  let label = "small";
  if (value > 100) {
    label = "huge";
  } else if (value > 10) {
    label = "medium";
  }
  let suffix = "";
  if (value % 2 === 0) suffix = " even";
  return label + suffix;
}

function clamp(n: number, low: number, high: number): number {
  let result = n;
  if (result < low) {
    result = low;
  } else {
    if (result > high) {
      result = high;
    }
  }
  return result;
}

function firstValid(values: (number | null)[]): number {
  for (const v of values) {
    if (v === null) {
      continue;
    } else if (v < 0) {
      return -1;
    } else {
      return v;
    }
  }
  return 0;
}

function main(): void {
  console.log(grade(95), grade(85), grade(72), grade(10));
  console.log(sign(5), sign(-2), sign(0));
  console.log(describe(5), describe(50), describe(500), describe(7));
  console.log(clamp(5, 0, 10), clamp(-5, 0, 10), clamp(50, 0, 10));
  console.log(firstValid([null, null, 7]), firstValid([null, -3]), firstValid([]));
}

main();
