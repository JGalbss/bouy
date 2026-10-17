// Array methods with closures over mutable state.
const nums = [5, 3, 8, 1, 9, 2];
let visits = 0;
const evens = nums.filter((n) => {
  visits++;
  return n % 2 === 0;
});
console.log(evens, visits);
const sorted = [...nums].sort((a, b) => a - b);
console.log(sorted, nums);
console.log(nums.map((n, i) => n * i).reduce((acc, n) => acc + n, 0));
console.log(
  nums.find((n) => n > 5),
  nums.findIndex((n) => n > 5),
  nums.includes(9),
  nums.indexOf(42),
);
const removed = nums.splice(1, 2, 100);
console.log(removed, nums);
const grid = Array.from({ length: 3 }, (_, r) => Array.from({ length: 3 }, (_, c) => r * 3 + c));
grid[1][1] = -1;
console.log(grid.map((row) => row.join(",")).join(" | "));
const stack: number[] = [];
stack.push(1, 2, 3);
console.log(stack.pop(), stack.shift(), stack, stack.length);
console.log([3, 1, 2].toSorted?.() ?? "no toSorted", ["b", "a"].sort(), [1, [2, [3]]].flat(2));
