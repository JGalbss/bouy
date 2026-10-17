// Promise.all, race, allSettled, and any, with resolution order.
const wait = <T>(value: T, ms: number) => new Promise<T>((r) => setTimeout(() => r(value), ms));
const reject = (message: string, ms: number) =>
  new Promise<never>((_, r) => setTimeout(() => r(new Error(message)), ms));

async function main() {
  console.log(await Promise.all([wait("a", 20), wait("b", 5), "c"]));
  console.log(await Promise.race([wait("slow", 30), wait("fast", 5)]));
  const settled = await Promise.allSettled([wait(1, 5), reject("no", 1)]);
  console.log(
    settled.map((s) => (s.status === "fulfilled" ? s.value : (s.reason as Error).message)),
  );
  console.log(await Promise.any([reject("x", 1), wait("first ok", 10), wait("second ok", 20)]));
  try {
    await Promise.any([reject("e1", 1), reject("e2", 2)]);
  } catch (e) {
    console.log((e as AggregateError).errors.map((x: Error) => x.message));
  }
  try {
    await Promise.all([wait(1, 5), reject("all failed", 1)]);
  } catch (e) {
    console.log((e as Error).message);
  }
  const { promise, resolve } = Promise.withResolvers<string>();
  setTimeout(() => resolve("resolved later"), 1);
  console.log(await promise);
}
main();
