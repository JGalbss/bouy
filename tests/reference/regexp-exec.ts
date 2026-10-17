// RegExp objects and exec: literals and the constructor, flags, lastIndex with g and y,
// captures and named groups, match indices, backtracking order, lookarounds,
// backreferences, and the syntax errors of patterns built at run time.

const show = (value: unknown): string => JSON.stringify(value);

function exec(re: RegExp, input: string): string {
  const m = re.exec(input);
  if (m === null) return "null";
  const groups = m.groups === undefined ? "" : ` groups=${show({ ...m.groups })}`;
  const indices = m.indices === undefined ? "" : ` indices=${show([...m.indices])}`;
  return `${show([...m])} index=${m.index} lastIndex=${re.lastIndex}${groups}${indices}`;
}

const date = /(?<year>\d{4})-(?<month>\d{2})(?:-(?<day>\d{2}))?/;
console.log(exec(date, "due 2024-05 and 2025-01-31"));
console.log(date.source, date.flags, date.global, date.lastIndex, String(date));

const words = /\w+/g;
const found: string[] = [];
for (let m = words.exec("one two  three"); m !== null; m = words.exec("one two  three")) {
  found.push(`${m[0]}@${m.index}:${words.lastIndex}`);
}
console.log(found.join(" "), words.lastIndex);

const sticky = /foo/y;
console.log(exec(sticky, "foofoo bar"), exec(sticky, "foofoo bar"), exec(sticky, "foofoo bar"));
sticky.lastIndex = 1;
console.log(sticky.test("xfoo"), sticky.lastIndex, sticky.test("xfoo"), sticky.lastIndex);

console.log(exec(/a|ab/, "abc"), exec(/((a)|(ab))((c)|(bc))/, "abc"));
console.log(exec(/a[a-z]{2,4}/, "abcdefghi"), exec(/a[a-z]{2,4}?/, "abcdefghi"));
console.log(exec(/(aa|aabaac|ba|b|c)*/, "aabaac"), exec(/(z)((a+)?(b+)?(c))*/, "zaacbbbcac"));
console.log(exec(/(a*)*/, "b"), exec(/(a*)b\1+/, "baaaac"));
console.log(exec(/(?=(a+))/, "baaabac"), exec(/(?=(a+))a*b\1/, "baaabac"));
console.log(exec(/(.*?)a(?!(a+)b\2c)\2(.*)/, "baaabaac"));
console.log("aaaaaaaaaa,aaaaaaaaaaaaaaa".replace(/^(a+)\1*,\1+$/, "$1"));
console.log(exec(/(?<=\$)\d+(\.\d*)?/, "cost $10.53"), exec(/(?<!\$)\b\d+/, "$10 20"));
console.log(exec(/(?<=(\d+)(\d+))$/, "1053"), exec(/(?<=\1(a))b/, "aab"));
console.log(exec(/(?<a>x)|(?<a>y)/, "-y-"), exec(/\k<n>(?<n>b)\k<n>/, "abb"));
console.log(exec(/(?i:ab)c/, "ABc ABC"), exec(/(?-i:a)b/i, "Ab aB"), exec(/^b/m, "a\nb"));
console.log(exec(/a.c/s, "a\nc"), exec(/a.c/, "a\nc"), exec(/\bfoo\b/, "afoo foo"));
console.log(exec(/(\d)(?<x>\d)?/d, "a1b"), exec(/(?<w>[a-z]+)/dg, "  ab"));
console.log(exec(/x{2,3}|{|\8|\00/, "{"), exec(/[\b]\cJ\x41B/, "\b\nAB"));

const built = new RegExp("[a-c]+", "gi");
console.log(
  built.source,
  built.flags,
  "xxABCabcx".match(built),
  new RegExp(built).flags,
  new RegExp(built, "y").flags,
);
console.log(
  RegExp("a") instanceof RegExp,
  new RegExp("/", "").source,
  new RegExp("\n").source,
  new RegExp("").source,
);
console.log(
  Object.prototype.toString.call(/x/),
  RegExp.prototype.source,
  RegExp.prototype.flags,
  typeof RegExp.prototype.global,
);
for (const bad of ["(", "a**", "[b-a]", "(?<n>a)(?<n>b)", "\\k<x>", "x{2,1}"]) {
  try {
    new RegExp(bad, "u");
    console.log("accepted", bad);
  } catch (e) {
    console.log((e as Error).name, (e as Error).message);
  }
}
try {
  new RegExp("a", "gg");
} catch (e) {
  console.log((e as Error).name, (e as Error).message);
}

const legacy = RegExp as unknown as Record<string, string>;
/(\d+)-(\d+)/.exec("ab 12-34 cd");
console.log(
  legacy.$1,
  legacy.$2,
  legacy.$3,
  legacy.lastMatch,
  legacy.lastParen,
  legacy["$`"],
  legacy["$'"],
);
legacy.input = "set";
console.log(legacy.$_, legacy.$1);

const original = /a(b)/gi;
original.lastIndex = 2;
const copy = structuredClone(original);
console.log(
  copy !== original,
  copy instanceof RegExp,
  String(copy),
  copy.lastIndex,
  copy.exec("xAB")?.[1],
);
