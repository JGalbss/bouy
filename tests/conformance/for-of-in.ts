function main(): void {
  let total = 0;
  for (const n of [1, 2, 3, 4]) {
    total += n;
  }
  console.log(total);
  const letters: string[] = [];
  for (const ch of "héllo") {
    letters.push(ch);
  }
  console.log(letters.join("."), letters.length);
  const scores = new Map([
    ["ann", 3],
    ["bob", 5],
  ]);
  let best = "";
  let bestScore = -1;
  for (const [name, score] of scores) {
    if (score > bestScore) {
      best = name;
      bestScore = score;
    }
  }
  console.log(best, bestScore);
  const keys: string[] = [];
  const record = { apple: 1, banana: 2, cherry: 3 };
  for (const key in record) {
    keys.push(key);
  }
  console.log(keys.join(","));
  for (const index in ["x", "y"]) {
    console.log(index, typeof index);
  }
  let product = 1;
  for (const value of new Set([2, 3, 4])) {
    product *= value;
  }
  console.log(product);
  for (const [i, v] of ["a", "b"].entries()) {
    console.log(i, v);
  }
  let found = "none";
  for (const word of ["alpha", "beta", "gamma"]) {
    if (word.startsWith("b")) {
      found = word;
      break;
    }
  }
  console.log(found);
}

main();
