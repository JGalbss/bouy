function sieve(limit: number): number[] {
  const composite: boolean[] = new Array(limit + 1).fill(false);
  const primes: number[] = [];
  for (let n = 2; n <= limit; n++) {
    if (composite[n]) continue;
    primes.push(n);
    for (let multiple = n * n; multiple <= limit; multiple += n) {
      composite[multiple] = true;
    }
  }
  return primes;
}

function gcd(a: number, b: number): number {
  return b === 0 ? a : gcd(b, a % b);
}

function lcm(a: number, b: number): number {
  return (a / gcd(a, b)) * b;
}

function factorize(n: number): string {
  const factors: number[] = [];
  let rest = n;
  for (let d = 2; d * d <= rest; d++) {
    while (rest % d === 0) {
      factors.push(d);
      rest /= d;
    }
  }
  if (rest > 1) factors.push(rest);
  return factors.join("x");
}

function main(): void {
  const primes = sieve(60);
  console.log(primes.length, primes.join(" "));
  console.log(gcd(48, 18), gcd(17, 5), lcm(4, 6), lcm(21, 6));
  console.log(factorize(360), factorize(97), factorize(1001));
}

main();
