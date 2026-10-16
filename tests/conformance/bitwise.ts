function main(): void {
  console.log(5 & 3, 5 | 3, 5 ^ 3, ~5, ~-1);
  console.log(1 << 4, 256 >> 2, -16 >> 2, -16 >>> 28);
  console.log(0xff & 0x0f, 0b1010 | 0b0101, 0o17);
  console.log((2 ** 32) | 0, (2 ** 31) | 0, 4294967295 >>> 0);
  console.log(3.7 | 0, -3.7 | 0, ~~9.99);
  let flags = 0;
  flags |= 1 << 2;
  flags |= 1;
  flags &= ~1;
  flags ^= 8;
  console.log(flags, (flags & 4) !== 0, (flags & 1) !== 0);
  let x = 1;
  x <<= 10;
  x >>= 3;
  console.log(x);
}

main();
