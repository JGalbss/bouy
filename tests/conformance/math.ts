function main(): void {
  console.log(Math.max(3, 9, 2), Math.min(3, 9, 2), Math.max(), Math.min());
  console.log(Math.abs(-4.5), Math.floor(2.7), Math.ceil(2.1), Math.trunc(-2.7));
  console.log(Math.sqrt(16), Math.pow(2, 8), Math.sign(-3), Math.sign(0));
  console.log(Math.round(1.5), Math.round(-1.5), Math.round(0.49));
  console.log(Math.PI.toFixed(5), Math.E.toFixed(3));
  console.log(Math.hypot(3, 4), Math.cbrt(27), Math.log2(1024));
  console.log(Math.max(...[4, 8, 15, 16, 23, 42]));
  const r = Math.random();
  console.log(r >= 0 && r < 1);
  console.log(Math.floor(-0.5), Math.min(1, NaN));
}

main();
