export function total(items: number[]): number {
  let sum = 0;
  items.forEach((item) => {
    sum += item;
  });
  const seen: number[] = [];
  items.forEach((item) => seen.push(item));
  return sum + seen.length;
}
