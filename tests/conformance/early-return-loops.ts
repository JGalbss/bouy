function findInGrid(grid: string[][], target: string): string {
  for (let r = 0; r < grid.length; r++) {
    const row = grid[r];
    for (let c = 0; c < row.length; c++) {
      if (row[c] === "#") continue;
      if (row[c] === target) {
        return `found at ${r},${c}`;
      }
      if (row[c] === "!") break;
    }
  }
  return "not found";
}

function firstDuplicate(xs: number[]): number {
  const seen = new Set<number>();
  for (const x of xs) {
    if (seen.has(x)) return x;
    seen.add(x);
  }
  return -1;
}

function process(commands: string[]): string {
  let total = 0;
  let index = 0;
  while (index < commands.length) {
    const command = commands[index];
    index++;
    switch (command) {
      case "inc":
        total++;
        break;
      case "double":
        total *= 2;
        break;
      case "skip":
        index++;
        continue;
      case "halt":
        return `halted with ${total} at ${index}`;
      default:
        if (command.startsWith("add")) {
          total += Number(command.slice(3));
          break;
        }
        return `bad command ${command}`;
    }
    if (total > 100) {
      return `overflow ${total}`;
    }
  }
  return `finished with ${total}`;
}

function main(): void {
  const grid = [
    ["a", "#", "b"],
    ["c", "!", "x"],
    ["#", "x", "d"],
  ];
  console.log(findInGrid(grid, "b"), "|", findInGrid(grid, "x"), "|", findInGrid(grid, "z"));
  console.log(firstDuplicate([3, 1, 4, 1, 5]), firstDuplicate([1, 2]));
  console.log(process(["inc", "inc", "double", "add5", "skip", "inc", "inc"]));
  console.log(process(["inc", "halt", "inc"]));
  console.log(process(["add60", "double"]));
  console.log(process(["oops"]));
}

main();
