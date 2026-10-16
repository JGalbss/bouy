/** JSON with sorted object keys, so that Node and Bouy print objects alike (section 3). */
export function show(value: unknown): string {
  return JSON.stringify(sorted(value));
}

function sorted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sorted);
  if (value instanceof Date) return value.toISOString();
  if (value === null || typeof value !== "object") return value;
  const record = value as Record<string, unknown>;
  return Object.fromEntries(
    Object.keys(record)
      .sort()
      .map((key) => [key, sorted(record[key])]),
  );
}
