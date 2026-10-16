type Matrix = number[][];

function multiply(a: Matrix, b: Matrix): Matrix {
  const result: Matrix = [];
  for (let i = 0; i < a.length; i++) {
    const row: number[] = [];
    for (let j = 0; j < b[0].length; j++) {
      let sum = 0;
      for (let k = 0; k < b.length; k++) {
        sum += a[i][k] * b[k][j];
      }
      row.push(sum);
    }
    result.push(row);
  }
  return result;
}

function transpose(m: Matrix): Matrix {
  return m[0].map((_, column) => m.map((row) => row[column]));
}

function identity(n: number): Matrix {
  const rows: Matrix = [];
  for (let i = 0; i < n; i++) {
    const row = new Array(n).fill(0);
    row[i] = 1;
    rows.push(row);
  }
  return rows;
}

function show(m: Matrix): string {
  return m.map((row) => row.join(" ")).join(" / ");
}

function main(): void {
  const a = [
    [1, 2],
    [3, 4],
  ];
  const b = [
    [5, 6],
    [7, 8],
  ];
  console.log(show(multiply(a, b)));
  console.log(
    show(
      transpose([
        [1, 2, 3],
        [4, 5, 6],
      ]),
    ),
  );
  console.log(show(multiply(a, identity(2))));
  const grid = identity(3);
  grid[0][2] = 9;
  grid[2][0] += 4;
  console.log(show(grid));
}

main();
