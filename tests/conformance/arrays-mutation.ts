function main(): void {
  const xs: number[] = [];
  xs.push(1);
  xs.push(2, 3);
  console.log(xs.length, xs.join(","));
  const last = xs.pop();
  console.log(last, xs.join(","));
  xs.unshift(0);
  console.log(xs.join(","));
  const first = xs.shift();
  console.log(first, xs.join(","));
  const ys = [1, 2, 3, 4, 5];
  const removed = ys.splice(1, 2);
  console.log(removed.join(","), ys.join(","));
  ys.splice(1, 0, 9, 9);
  console.log(ys.join(","));
  ys.reverse();
  console.log(ys.join(","));
  const zs = new Array(3).fill(0);
  console.log(zs.join(","));
  zs[1] = 7;
  console.log(zs.join(","));
  const grid = [
    [0, 0],
    [0, 0],
  ];
  grid[1][0] = 5;
  grid[0].push(1);
  console.log(JSON.stringify(grid));
  const copy = [...ys];
  copy.push(100);
  console.log(ys.length, copy.length);
}

main();
