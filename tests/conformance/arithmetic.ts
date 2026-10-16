function main(): void {
  console.log(1 + 2, 7 - 10, 6 * 7);
  console.log(10 / 2, 10 / 4, 1 / 3);
  console.log(7 % 3, -7 % 3, 7.5 % 2);
  console.log(2 ** 10, 2 ** 0.5, 2 ** -1);
  console.log(0.1 + 0.2, 0.5 + 0.25);
  console.log(1 / 0, -1 / 0, 0 / 0);
  console.log(Number.MAX_SAFE_INTEGER, -Number.MAX_SAFE_INTEGER);
  console.log(1e21, 1e-7, 123456789.125);
  console.log(-5, +"42", +"", +"abc");
  const big = 2 ** 31;
  console.log(big, big * 2, big - 1);
  let n = 10;
  n += 5;
  n -= 3;
  n *= 2;
  n /= 4;
  n %= 4;
  console.log(n);
  let i = 0;
  const before = i++;
  const after = ++i;
  console.log(before, after, i);
  let j = 5;
  j--;
  --j;
  console.log(j);
}

main();
