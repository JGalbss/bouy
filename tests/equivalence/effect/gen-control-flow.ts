// yield* inside if, else, switch, for, for...of, while, and nested Effect.gen.
import { Effect } from "effect";

const double = (n: number) => Effect.succeed(n * 2);
const describe = (n: number) => (n % 2 === 0 ? Effect.succeed("even") : Effect.succeed("odd"));

const program = Effect.gen(function* () {
  const lines: string[] = [];
  let sum = 0;
  for (let i = 0; i < 4; i++) {
    sum += yield* double(i);
  }
  lines.push(`for: ${sum}`);

  for (const n of [3, 4]) {
    if (n > 3) {
      lines.push(`${n} is ${yield* describe(n)} and big`);
    } else {
      lines.push(`${n} is ${yield* describe(n)}`);
    }
  }

  let countdown = 3;
  while (countdown > 0) {
    countdown = (yield* Effect.succeed(countdown)) - 1;
    if (countdown === 1) {
      continue;
    }
    lines.push(`while: ${countdown}`);
  }

  const kind = yield* Effect.succeed("b");
  switch (kind) {
    case "a":
      lines.push("switch: a");
      break;
    case "b":
      lines.push(`switch: b ${yield* double(5)}`);
      break;
    default:
      lines.push("switch: other");
  }

  const inner = yield* Effect.gen(function* () {
    const a = yield* double(10);
    const b = yield* double(a);
    return a + b;
  });
  lines.push(`nested: ${inner}`);

  const found = yield* findFirstEven([1, 3, 6, 8]);
  lines.push(`early return: ${found}`);
  return lines;
});

function findFirstEven(items: number[]) {
  return Effect.gen(function* () {
    for (const item of items) {
      const kind = yield* describe(item);
      if (kind === "even") {
        return item;
      }
    }
    return -1;
  });
}

for (const line of Effect.runSync(program)) {
  console.log(line);
}
console.log(Effect.runSync(findFirstEven([1, 5])));
