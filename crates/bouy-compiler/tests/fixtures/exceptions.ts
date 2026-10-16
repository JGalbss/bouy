export function caught(n: number): string {
  let result = "none";
  try {
    if (n < 0) throw new RangeError("negative");
    result = "ok";
  } catch (e) {
    result = (e as Error).message;
  } finally {
    console.log("done");
  }
  return result;
}

export function returnsFromTry(n: number): number {
  try {
    if (n > 0) return n;
  } catch {
    return -1;
  }
  return 0;
}

export function countsBeforeThrow(): number {
  let count = 0;
  try {
    count++;
    throw new Error("stop");
  } catch {
    count += 10;
  }
  return count;
}

export function finallyRebinds(): string[] {
  const log: string[] = [];
  try {
    log.push("body");
  } finally {
    log.push("finally");
  }
  return log;
}
