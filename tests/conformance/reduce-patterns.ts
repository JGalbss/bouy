interface Item {
  category: string;
  price: number;
}

function main(): void {
  const items: Item[] = [
    { category: "fruit", price: 3 },
    { category: "veg", price: 2 },
    { category: "fruit", price: 5 },
    { category: "dairy", price: 4 },
    { category: "veg", price: 1 },
  ];
  const totals = items.reduce((acc: Record<string, number>, item) => {
    return { ...acc, [item.category]: (acc[item.category] ?? 0) + item.price };
  }, {});
  for (const category of Object.keys(totals).sort()) {
    console.log(category, totals[category]);
  }
  const [cheap, pricey] = items.reduce(
    ([low, high]: [Item[], Item[]], item) =>
      item.price < 3 ? [[...low, item], high] : [low, [...high, item]],
    [[], []] as [Item[], Item[]],
  );
  console.log(cheap.length, pricey.length);
  const max = items.reduce((best, item) => (item.price > best.price ? item : best));
  console.log(max.category, max.price);
  const running = items
    .map((item) => item.price)
    .reduce((acc: number[], price) => [...acc, (acc[acc.length - 1] ?? 0) + price], []);
  console.log(running.join(","));
  console.log([[1, 2], [3]].reduceRight((acc, xs) => acc.concat(xs), [] as number[]).join(","));
}

main();
