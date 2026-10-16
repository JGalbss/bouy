function parseAll(inputs: string[]): string {
  let ok = 0;
  let failed = 0;
  let last = "none";
  for (const input of inputs) {
    try {
      const value = JSON.parse(input);
      last = String(value);
      ok++;
    } catch {
      failed++;
      last = "error";
    }
  }
  return `${ok} ok, ${failed} failed, last ${last}`;
}

function finallyOrder(throwIt: boolean): string {
  const events: string[] = [];
  try {
    events.push("start");
    try {
      events.push("inner");
      if (throwIt) throw new Error("boom");
      events.push("inner-done");
    } finally {
      events.push("inner-finally");
    }
    events.push("after-inner");
  } catch (e) {
    events.push("caught " + (e as Error).message);
  }
  events.push("end");
  return events.join(" > ");
}

function breakFromTry(): string {
  let attempts = 0;
  let result = "pending";
  while (true) {
    attempts++;
    try {
      if (attempts < 3) throw new Error("not yet");
      result = "done";
      break;
    } catch (e) {
      result = (e as Error).message;
    }
  }
  return `${result} after ${attempts}`;
}

function returnInFinallyPath(n: number): string {
  try {
    if (n === 0) return "zero";
    if (n < 0) throw new Error("negative");
    return "positive";
  } catch (e) {
    return "caught " + (e as Error).message;
  } finally {
    console.log("cleanup", n);
  }
}

function countBeforeThrow(): string {
  let count = 0;
  try {
    count++;
    count++;
    throw new Error("stop");
  } catch {
    count += 100;
  }
  return String(count);
}

function main(): void {
  console.log(parseAll(["1", "{", "true", "[2"]));
  console.log(finallyOrder(false));
  console.log(finallyOrder(true));
  console.log(breakFromTry());
  console.log(returnInFinallyPath(0), returnInFinallyPath(-1), returnInFinallyPath(4));
  console.log(countBeforeThrow());
}

main();
