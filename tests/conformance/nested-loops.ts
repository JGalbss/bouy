function findPair(xs: number[], target: number): string {
  for (let i = 0; i < xs.length; i++) {
    for (let j = i + 1; j < xs.length; j++) {
      if (xs[i] + xs[j] === target) {
        return `${i},${j}`;
      }
    }
  }
  return "none";
}

function countSkipping(limit: number): number {
  let count = 0;
  for (let i = 0; i < limit; i++) {
    if (i % 2 === 0) continue;
    for (let j = 0; j < limit; j++) {
      if (j > i) break;
      if (j % 3 === 0) continue;
      count++;
    }
  }
  return count;
}

function firstRowWithZero(grid: number[][]): number {
  let row = -1;
  for (let r = 0; r < grid.length; r++) {
    for (const cell of grid[r]) {
      if (cell === 0) {
        row = r;
        break;
      }
    }
    if (row !== -1) break;
  }
  return row;
}

function main(): void {
  console.log(findPair([1, 4, 6, 9], 10), findPair([1, 2], 10));
  console.log(countSkipping(6), countSkipping(10));
  console.log(firstRowWithZero([[1, 2], [3, 0], [0]]), firstRowWithZero([[1]]));
  const triangle: string[] = [];
  for (let i = 1; i <= 4; i++) {
    let line = "";
    for (let j = 0; j < i; j++) {
      line += "*";
    }
    triangle.push(line);
  }
  console.log(triangle.join("|"));
}

main();
