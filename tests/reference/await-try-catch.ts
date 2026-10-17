// try/catch around await: rejections become throws, and catch can await again.
function fail(message: string, ms: number): Promise<never> {
  return new Promise((_, reject) => setTimeout(() => reject(new Error(message)), ms));
}
function later<T>(value: T, ms: number): Promise<T> {
  return new Promise((resolve) => setTimeout(() => resolve(value), ms));
}

async function attempt(n: number): Promise<string> {
  const steps: string[] = [];
  try {
    steps.push("try");
    const v = await later(n, 1);
    steps.push(`got ${v}`);
    if (n > 1) await fail(`too big: ${n}`, 1);
    steps.push("after");
  } catch (e) {
    steps.push(`caught ${(e as Error).message}`);
    const recovered = await later("recovered", 1);
    steps.push(recovered);
  }
  steps.push("end");
  return steps.join(" > ");
}

async function nested(): Promise<string> {
  try {
    try {
      await fail("inner", 1);
    } catch (e) {
      throw new Error(`rethrown ${(e as Error).message}`);
    }
  } catch (e) {
    return (e as Error).message;
  }
  return "unreachable";
}

async function main() {
  console.log(await attempt(1));
  console.log(await attempt(2));
  console.log(await nested());
  try {
    await Promise.reject(new TypeError("plain"));
  } catch (e) {
    console.log(e instanceof TypeError, (e as Error).name, (e as Error).message);
  }
  const results = await Promise.allSettled([later(1, 2), fail("x", 1)]);
  console.log(results.map((r) => r.status));
}

main();
