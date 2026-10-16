interface Person {
  name: string;
  age: number;
}

function main(): void {
  const nums = [10, 1, 5, 100, 25];
  const asc = [...nums].sort((a, b) => a - b);
  const desc = [...nums].sort((a, b) => b - a);
  console.log(asc.join(","), desc.join(","));
  const words = ["pear", "apple", "fig", "banana"];
  words.sort();
  console.log(words.join(","));
  const byLength = [...words].sort((a, b) => a.length - b.length || (a < b ? -1 : 1));
  console.log(byLength.join(","));
  const people: Person[] = [
    { name: "Ann", age: 31 },
    { name: "Bob", age: 25 },
    { name: "Cid", age: 31 },
    { name: "Dee", age: 19 },
  ];
  const sorted = [...people].sort((a, b) => a.age - b.age);
  console.log(sorted.map((p) => p.name).join(","));
  console.log(nums.toString());
  const reversed = [1, 2, 3].reverse();
  console.log(reversed.join(""));
}

main();
