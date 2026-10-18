export function factorial(): number {
  let fact = (n: number): number => n;
  fact = (n: number): number => (n <= 1 ? 1 : n * fact(n - 1));
  return fact(5);
}

export function help(): string {
  const commands: Record<string, () => string> = {};
  commands.quit = () => "bye";
  commands.help = () => Object.keys(commands).join(", ");
  return commands.help();
}

export function recursive(): number {
  const table = new Map<string, (n: number) => number>();
  table.set("fact", (n) => (n <= 1 ? 1 : n * table.get("fact")!(n - 1)));
  return table.get("fact")!(4);
}

export function consumed(items: number[]): number {
  let count = 2;
  count = items.filter((item) => item > count).length;
  return count;
}
