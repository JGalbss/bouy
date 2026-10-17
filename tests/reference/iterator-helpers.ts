// The iterator helpers of ES2025: lazy map, filter, take, drop, and flatMap, which close
// the iterator they read when they stop early, the eager methods, Iterator.from, and an
// Iterator subclass.
function* naturals() {
  let n = 0;
  try {
    while (true) yield n++;
  } finally {
    console.log("naturals closed");
  }
}

console.log(
  naturals()
    .map((x) => x * 2)
    .filter((x) => x % 3 === 0)
    .take(4)
    .toArray(),
);
console.log(naturals().drop(5).take(3).toArray());
console.log([1, 2, 3].values().reduce((sum, x) => sum + x));
console.log(
  naturals().some((x) => x > 3),
  naturals().find((x) => x === 7),
);
console.log(
  naturals()
    .take(3)
    .flatMap((x) => [x, -x])
    .toArray(),
);
naturals()
  .take(2)
  .forEach((x, i) => console.log("each", x, i));

const plain = Iterator.from({
  next() {
    return { value: "plain", done: false };
  },
});
console.log(plain.take(2).toArray());

const helper = naturals().map((x) => x);
helper.next();
console.log(helper.return());
console.log(Object.prototype.toString.call(helper), Iterator.prototype.map.length);

try {
  new (Iterator as any)();
} catch (error) {
  console.log("abstract:", (error as Error).constructor.name);
}
class Countdown extends Iterator<number> {
  n = 3;
  next(): IteratorResult<number> {
    return this.n > 0 ? { value: this.n--, done: false } : { value: undefined, done: true };
  }
}
console.log(new Countdown().toArray(), new Countdown() instanceof Iterator);
try {
  naturals().take(-1);
} catch (error) {
  console.log("negative limit:", (error as Error).constructor.name);
}
