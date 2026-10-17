// Hoisted functions and closures that read bindings declared after them, the temporal dead
// zone, and the order of a method call.
function outer(): number {
  function helper(): number {
    return config.scale * later();
  }
  const config = { scale: 3 };
  const later = (): number => offset + 1;
  const offset = 1;
  return helper();
}
console.log(outer());

const errorText = (run: () => unknown): string => {
  try {
    run();
    return "no error";
  } catch (error) {
    return `${(error as Error).constructor.name}: ${(error as Error).message}`;
  }
};
function deadZone(): string {
  const read = (): number => value;
  const before = errorText(read);
  const value = 7;
  return `${before} / ${read()}`;
}
console.log(deadZone());
function defaults(first = second, second = 1): number {
  return first + second;
}
console.log(
  errorText(() => defaults()),
  defaults(2),
);

const log: string[] = [];
const target = {
  get method(): (value: number) => number {
    log.push("get method");
    return (value: number) => value;
  },
};
const argument = (): number => {
  log.push("argument");
  return 1;
};
target.method(argument());
console.log(log.join(", "));
const empty = { nested: undefined as unknown as { call(value: unknown): void } };
let evaluated = false;
console.log(
  errorText(() => empty.nested.call((evaluated = true))),
  evaluated,
);
