export function later(): number {
  let value = 1;
  const read = () => value;
  value = 2;
  return read();
}

export function inLoop(): number[] {
  const readers: (() => number)[] = [];
  let i = 0;
  while (i < 3) {
    readers.push(() => i);
    i++;
  }
  return readers.map((read) => read());
}
