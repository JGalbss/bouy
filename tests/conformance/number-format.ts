function main(): void {
  console.log((3.14159).toFixed(2), (2.5).toFixed(0), (1.005).toFixed(2), (10).toFixed(3));
  console.log((255).toString(16), (255).toString(2), (8).toString(8));
  console.log(String(1.5), String(100), String(-0.5));
  console.log(parseInt("42px"), parseInt("ff", 16), parseInt("abc"));
  console.log(parseFloat("3.5kg"), parseFloat(".25"), parseFloat("x"));
  console.log(Number("12"), Number("1.5e3"), Number(""), Number("  7  "));
  console.log(Number.isInteger(5), Number.isInteger(5.5), Number.isNaN(NaN));
  console.log(isNaN(NaN), isFinite(10), isFinite(1 / 0));
  console.log(Math.round(2.5), Math.round(-2.5), Math.round(2.4));
  console.log(0.1 * 3, 100 / 3, 2 / 3);
  console.log(123e-20, 5e-324 > 0, 1.7976931348623157e308);
}

main();
