function risky(n: number): number {
  if (n < 0) throw new RangeError("negative: " + n);
  return Math.sqrt(n);
}

function safe(n: number): string {
  try {
    return "ok " + risky(n);
  } catch (e) {
    const error = e as Error;
    return `caught ${error.name}: ${error.message}`;
  }
}

function withFinally(n: number): string {
  const log: string[] = [];
  try {
    log.push("try");
    if (n > 0) {
      return "early";
    }
    log.push("after-if");
  } finally {
    console.log("finally for", n);
  }
  return log.join(",");
}

function rethrow(): string {
  try {
    try {
      throw new Error("inner");
    } catch (e) {
      throw new Error("outer wraps " + (e as Error).message);
    }
  } catch (e) {
    return (e as Error).message;
  }
}

function retry(attempts: number): string {
  let tries = 0;
  for (let i = 0; i < attempts; i++) {
    try {
      tries++;
      if (i < 2) throw new Error("flaky");
      return `succeeded after ${tries}`;
    } catch (e) {
      console.log("attempt", i, "failed");
    }
  }
  return `gave up after ${tries}`;
}

function main(): void {
  console.log(safe(16), "|", safe(-1));
  console.log(withFinally(1));
  console.log(withFinally(0));
  console.log(rethrow());
  console.log(retry(5));
  console.log(retry(1));
  try {
    throw "a plain string";
  } catch (e) {
    console.log("thrown value:", e);
  }
  try {
    null;
  } catch {
    console.log("never");
  } finally {
    console.log("done");
  }
}

main();
