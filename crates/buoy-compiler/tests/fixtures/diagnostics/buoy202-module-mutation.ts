const cache = new Map<string, number>();
const seen: string[] = [];

export function remember(key: string): void {
  cache.set(key, 1);
}

seen.push("start");
