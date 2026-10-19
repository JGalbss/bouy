// The methods of String.prototype that take a pattern: match, matchAll, replace,
// replaceAll, search, and split, through the Symbol.match, Symbol.replace, Symbol.search,
// and Symbol.split protocols, with $ patterns, replacer functions, and custom matchers.

const show = (value: unknown): string => JSON.stringify(value);

const text = "The year 1999 ended, 2000 began; 2024 was a leap year.";
console.log(show(text.match(/\d{4}/)), show(text.match(/\d{4}/g)), show(text.match(/x/g)));
console.log(show([...text.matchAll(/(\d{2})(\d{2})/g)].map((m) => [m[0], m[1], m[2], m.index])));
console.log(text.search(/\d/), text.search(/zzz/), "abc".search("c"));

console.log("10-20 30-40".replace(/(\d+)-(\d+)/g, "$2-$1"), "abc".replace(/b/, "[$&|$`|$'|$$]"));
console.log(
  "abc".replace(/(?<l>b)/, "<$<l>>"),
  "abc".replace(/(b)/, "$01$10$2$0"),
  "abc".replace("b", "$&$&"),
);
console.log(
  "a1b22c333".replace(/\d+/g, (m: string, offset: number) => `(${m.length}@${offset})`),
  "x-y".replace(/(?<a>\w)-(?<b>\w)/, (...args: unknown[]) => show(args)),
);
console.log("aaa".replace(/a*/g, "X"), "abc".replace(/(?:)/g, "-"), "😀😀".replace(/(?:)/gu, "-"));
console.log(
  "a.b.c".replaceAll(".", "!"),
  "a.b.c".replaceAll(/\./g, "?"),
  "aaa".replaceAll("a", "$&b"),
);
try {
  "abc".replaceAll(/b/, "x");
} catch (e) {
  console.log((e as Error).name);
}

console.log(show("a,b,,c".split(/,/)), show("a1b2c3".split(/\d/)), show("a1b2c3".split(/(\d)/)));
console.log(
  show("abc".split(/(?:)/)),
  show("".split(/x/)),
  show("".split(/(?:)/)),
  show("ab".split(/a*?/)),
);
console.log(
  show("ab".split(/a*/)),
  show("A<B>bold</B>and<CODE>coded</CODE>".split(/<(\/)?([^<>]+)>/)),
);
console.log(show("one two three".split(" ", 2)), show("x".split("")), show("a,b".split(undefined)));

const custom = {
  [Symbol.match]: (s: string) => `match:${s}`,
  [Symbol.replace]: (s: string, r: string) => `replace:${s}:${r}`,
  [Symbol.search]: (s: string) => s.length,
  [Symbol.split]: (s: string, limit: number) => [s, limit],
};
console.log(
  "str".match(custom as never),
  "str".replace(custom as never, "r"),
  "str".search(custom as never),
);
console.log(show("str".split(custom as never, 3)));

class Loud extends RegExp {
  exec(s: string) {
    const m = super.exec(s);
    if (m !== null) m[0] = m[0].toUpperCase();
    return m;
  }
}
console.log(
  "a b c".replace(new Loud("[ab]", "g"), "<$&>"),
  new Loud("b").test("abc"),
  "ab".match(new Loud("b"))?.[0],
);
// The limit converts after the splitter exists, so its valueOf may replace exec.
const savedExec = RegExp.prototype.exec;
const splitByA = /a/[Symbol.split]("abba", {
  valueOf() {
    RegExp.prototype.exec = () => null;
    return 100;
  },
} as unknown as number);
RegExp.prototype.exec = savedExec;
console.log(splitByA);
