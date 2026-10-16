function assignInCondition(): string {
  const queue = [3, 2, 1, 0, 5];
  let n = 0;
  let index = 0;
  const seen: number[] = [];
  while ((n = queue[index++]) > 0) {
    seen.push(n);
  }
  return `${seen.join(",")} stop=${n} index=${index}`;
}

function chained(): string {
  let a = 0;
  let b = 0;
  let c = 0;
  a = b = c = 7;
  const arr = [0, 0, 0];
  let i = 0;
  arr[i++] = 10;
  arr[i++] += 5;
  arr[++i - 1] = 99;
  return `${a}${b}${c} ${arr.join(",")} ${i}`;
}

function weirdIncrements(): string {
  let x = 1;
  const y = x++ + ++x;
  let z = 5;
  z = z++ * 2;
  return `${x} ${y} ${z}`;
}

function mutationInTernary(flag: boolean): string {
  const items: number[] = [];
  const result = flag ? items.push(1, 2) : items.length;
  const other = !flag || items.push(3);
  return `${result} ${other} ${items.join(",")}`;
}

function tryInLoop(values: number[]): string {
  const log: string[] = [];
  let total = 0;
  for (const value of values) {
    try {
      if (value < 0) continue;
      if (value === 0) break;
      if (value > 100) return `too big after ${total}: ${log.join(" ")}`;
      total += value;
    } finally {
      log.push(`v${value}`);
    }
  }
  return `${total}: ${log.join(" ")}`;
}

function closuresInBranches(useDouble: boolean): number[] {
  let transform: (x: number) => number;
  if (useDouble) {
    const factor = 2;
    transform = (x) => x * factor;
  } else {
    transform = (x) => x + 1;
  }
  return [1, 2, 3].map(transform);
}

function nestedFunctions(base: number): number {
  function add(x: number): number {
    return x + base;
  }
  function twice(x: number): number {
    return add(add(x));
  }
  return twice(1);
}

function objectArrow(): string {
  const make = (id: number) => ({ id, label: `item-${id}` });
  const items = [1, 2].map(make);
  return items.map((item) => `${item.id}:${item.label}`).join(",");
}

function forInDelete(): string {
  const scores: Record<string, number> = { amy: 3, bob: 0, cid: 5 };
  for (const name in scores) {
    if (scores[name] === 0) delete scores[name];
  }
  return Object.keys(scores).join(",");
}

function swapLoop(): string {
  const xs = [5, 4, 3, 2, 1];
  for (let i = 0; i < xs.length - 1; i += 2) {
    [xs[i], xs[i + 1]] = [xs[i + 1], xs[i]];
  }
  return xs.join(",");
}

function nestedTernaryRebinding(n: number): string {
  let tag = "";
  const size = n > 10 ? ((tag = "big"), n * 2) : n > 5 ? ((tag = "mid"), n) : ((tag = "small"), 0);
  return `${tag}:${size}`;
}

function switchTryContinue(commands: string[]): string {
  let done = 0;
  let failed = 0;
  for (const command of commands) {
    switch (command) {
      case "ok":
        done++;
        continue;
      case "fail":
        try {
          throw new Error("bad");
        } catch {
          failed++;
          continue;
        }
      default:
        break;
    }
    done += 100;
  }
  return `${done}/${failed}`;
}

function main(): void {
  console.log(assignInCondition());
  console.log(chained());
  console.log(weirdIncrements());
  console.log(mutationInTernary(true), "|", mutationInTernary(false));
  console.log(tryInLoop([1, 2, -1, 3]));
  console.log(tryInLoop([1, 0, 5]));
  console.log(tryInLoop([4, 500, 6]));
  console.log(closuresInBranches(true).join(","), closuresInBranches(false).join(","));
  console.log(nestedFunctions(10));
  console.log(objectArrow());
  console.log(forInDelete());
  console.log(swapLoop());
  console.log(nestedTernaryRebinding(20), nestedTernaryRebinding(7), nestedTernaryRebinding(1));
  console.log(switchTryContinue(["ok", "fail", "x", "ok"]));
}

main();
