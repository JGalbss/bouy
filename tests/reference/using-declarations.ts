// Explicit resource management: `using` and `await using` dispose their resources,
// newest first, when their block ends, also by a return, a break, or a throw, and the
// errors of disposal become SuppressedErrors. DisposableStack and AsyncDisposableStack
// hold resources until their dispose method runs.
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

function stacks(): void {
  const stack = new DisposableStack();
  stack.use(resource("used"));
  stack.defer(() => console.log("deferred"));
  console.log(
    "adopted",
    stack.adopt(7, (value) => console.log("adopt", value)),
  );
  const moved = stack.move();
  console.log("disposed", stack.disposed, moved.disposed);
  try {
    stack.use(resource("late"));
  } catch (error) {
    console.log((error as Error).constructor.name);
  }
  {
    using scope = moved;
    console.log(Object.prototype.toString.call(scope));
  }
  console.log("disposed", moved.disposed);
  moved.dispose();

  const failing = new DisposableStack();
  failing.use(resource("first", true));
  failing.use(resource("second", true));
  try {
    failing.dispose();
  } catch (error) {
    const suppressed = error as SuppressedError;
    console.log(
      suppressed.constructor.name,
      (suppressed.error as Error).message,
      (suppressed.suppressed as Error).message,
    );
  }

  class Named extends DisposableStack {}
  const named = new Named();
  console.log(named instanceof Named, named.move() instanceof Named);
}
stacks();

async function asyncStacks(): Promise<void> {
  const stack = new AsyncDisposableStack();
  stack.use(resource("sync in async stack"));
  stack.defer(async () => {
    await null;
    console.log("async deferred");
  });
  stack.use(null);
  const pending = stack.disposeAsync();
  console.log("disposing", stack.disposed);
  console.log("resolved", await pending);
  try {
    await AsyncDisposableStack.prototype.disposeAsync.call({});
  } catch (error) {
    console.log("rejected", (error as Error).constructor.name);
  }
}

asynchronous()
  .then(() => console.log("async done"))
  .then(asyncStacks);
