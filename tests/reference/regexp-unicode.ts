// RegExp and Unicode: code units without a Unicode flag, code points with u and v,
// property escapes, case folding with i, class set operations and strings with v, and
// RegExp.escape.

const show = (value: unknown): string => JSON.stringify(value);
const all = (re: RegExp, s: string): string => show(s.match(re));

console.log(all(/./g, "a😀b"), all(/./gu, "a😀b"), "😀".match(/^.$/u) !== null, /^.$/.test("😀"));
console.log(
  /\u{1F600}/u.test("😀"),
  /\uD83D/.test("😀"),
  /\uD83D/u.test("😀"),
  /\uD83D/u.test("\uD83Dx"),
);
console.log(
  all(/\p{Lu}+/gu, "abcDÉFghiΩ"),
  all(/\p{Script=Greek}+/gu, "abc αβγ"),
  all(/\P{L}+/gu, "ab12;cd"),
);
console.log(
  all(/\p{Emoji_Presentation}/gu, "a😀b🎉"),
  /^\p{ASCII_Hex_Digit}+$/u.test("C0ffee"),
  /\p{Nd}/u.test("٣"),
);
console.log(
  /ſ/i.test("s"),
  /ſ/iu.test("s"),
  /\w/iu.test("ſ"),
  /\w/i.test("ſ"),
  /[a-z]/i.test("K"),
  /[a-z]/iu.test("K"),
);
console.log(
  /ß/i.test("SS"),
  /Σ/i.test("ς"),
  /σ/iu.test("ς"),
  /[^Σ]/iu.test("ς"),
  /K/i.test("k"),
  /K/iu.test("k"),
);
console.log(
  all(/[\p{L}--[a-z]]+/gv, "abcDEFghi"),
  all(/[\p{L}&&\p{Script=Latin}]+/gv, "abcαβ"),
  all(/[\q{abc|d}x]/gv, "xxabcd"),
);
console.log(
  all(/\p{RGI_Emoji}/gv, "a👍🏽b🇫🇷"),
  all(/[\p{ASCII}--\p{L}]+/gv, "ab12;cd"),
  /[^\d]/v.test("5"),
);
console.log(
  all(/(?<!\p{L})\d+/gu, "a1 22 x3"),
  "x😀y".split(/(?:)/u).length,
  "x😀y".split(/(?:)/).length,
);
console.log(
  RegExp.escape("a.b*c?"),
  RegExp.escape("1+1=2"),
  RegExp.escape("hello world"),
  RegExp.escape("_-$"),
);
for (const [pattern, flags] of [
  ["\\p{Unknown_Property}", "u"],
  ["[a-z&&b]", "v"],
  ["\\P{RGI_Emoji}", "v"],
  ["(?i-i:a)", ""],
] as const) {
  try {
    new RegExp(pattern, flags);
    console.log("accepted", pattern);
  } catch (e) {
    console.log((e as Error).name, (e as Error).message);
  }
}
