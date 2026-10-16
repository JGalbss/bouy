function frequencies(text: string): Map<string, number> {
  const counts = new Map<string, number>();
  for (const raw of text.toLowerCase().split(" ")) {
    const word = raw.replace(",", "").replace(".", "");
    if (word === "") continue;
    counts.set(word, (counts.get(word) ?? 0) + 1);
  }
  return counts;
}

function top(counts: Map<string, number>, n: number): string[] {
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
    .slice(0, n)
    .map(([word, count]) => `${word}:${count}`);
}

function main(): void {
  const text = "The quick brown fox. The lazy dog, the quick cat. A fox and a dog.";
  const counts = frequencies(text);
  console.log(counts.size);
  console.log(top(counts, 4).join(" "));
  const lengths = new Map<number, string[]>();
  for (const word of counts.keys()) {
    const group = lengths.get(word.length) ?? [];
    group.push(word);
    lengths.set(word.length, group);
  }
  const sizes = [...lengths.keys()].sort((a, b) => a - b);
  for (const size of sizes) {
    console.log(size, (lengths.get(size) ?? []).sort().join(","));
  }
}

main();
