// Explicit resource management: `using` and `await using` dispose their resources,
// newest first, when their block ends, also by a return, a break, or a throw, and the
// errors of disposal become SuppressedErrors.
function resource(name: string, fails = false): Disposable {
  return {
    [Symbol.dispose]() {
      console.log("dispose", name);
      if (fails) throw new Error(`dispose ${name}`);
    },
  };
}

function early(): string {
  using first = resource("first");
  using second = resource("second");
  console.log("body");
  return "returned";
}
console.log(early());

try {
  using a = resource("a", true);
  using b = resource("b", true);
  throw new Error("body");
} catch (error) {
  const suppressed = error as SuppressedError;
  console.log(suppressed.constructor.name, (suppressed.error as Error).message);
  const inner = suppressed.suppressed as SuppressedError;
  console.log(
    inner.constructor.name,
    (inner.error as Error).message,
    (inner.suppressed as Error).message,
  );
}

let count = 0;
for (let i = 0; i < 3; i++) {
  using step = resource(`step ${i}`);
  if (i === 1) continue;
  count += 10;
}
console.log("count", count);

for (using item of [resource("item 1"), resource("item 2")]) {
  console.log("loop body");
}

async function asynchronous(): Promise<void> {
  await using later = {
    async [Symbol.asyncDispose]() {
      await null;
      console.log("async dispose");
    },
  };
  await using fallback = resource("sync in await using");
  console.log("async body");
}
asynchronous().then(() => console.log("async done"));
