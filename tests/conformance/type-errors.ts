function callIt(fn: unknown): string {
  try {
    (fn as () => void)();
    return "called";
  } catch (e) {
    return e instanceof TypeError ? "TypeError" : "other";
  }
}

function main(): void {
  console.log(
    callIt(() => 1),
    callIt(undefined),
    callIt(42),
  );
  const obj: any = { name: "x" };
  try {
    obj.missing();
  } catch (e) {
    console.log(e instanceof TypeError, (e as Error).name);
  }
  try {
    const nothing: any = null;
    console.log(nothing.property);
  } catch (e) {
    console.log("null access:", (e as Error).name);
  }
  try {
    throw new TypeError("custom type error");
  } catch (e) {
    console.log((e as Error).message, e instanceof Error);
  }
}

main();
