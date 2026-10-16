interface Stats {
  count: number;
  total: number;
  history: number[];
  nested: { level: number };
}

function record(stats: Stats, value: number): Stats {
  stats.count += 1;
  stats.total += value;
  stats.history.push(value);
  stats.nested.level *= 2;
  return stats;
}

function main(): void {
  let stats: Stats = { count: 0, total: 0, history: [], nested: { level: 1 } };
  for (const v of [5, 10, 15]) {
    stats = record(stats, v);
  }
  console.log(stats.count, stats.total, stats.history.join(","), stats.nested.level);
  const arr = [1, 2, 3];
  arr[0] += 10;
  arr[1] *= 5;
  arr[2] **= 2;
  arr[arr.length - 1]--;
  console.log(arr.join(","));
  const counts: { [key: string]: number } = { hits: 0 };
  counts.hits++;
  ++counts.hits;
  counts["misses"] = (counts["misses"] || 0) + 1;
  console.log(counts.hits, counts.misses);
  const text = { value: "a" };
  text.value += "b";
  text.value += 1;
  console.log(text.value);
  const matrix = [
    [1, 2],
    [3, 4],
  ];
  matrix[1][1] -= 10;
  matrix[0] = [...matrix[0], 99];
  console.log(JSON.stringify(matrix));
}

main();
