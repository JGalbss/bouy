// RegExp edge cases, each checked against Node: backreferences with case folding and
// in lookbehind, the captures and empty checks of quantifiers, Annex B escapes, case
// folding with and without a Unicode flag, v-flag sets with i, lone surrogates, modifiers,
// and lastIndex with the g and y flags.

const cases: [string, string, string][] = [
  ["(a)\\1", "i", "aA"],
  ["(?<=(a)\\1)b", "i", "aAb"],
  ["(?<=\\1(a))b", "", "aab"],
  ["(a)|b", "g", "abab"],
  ["(?:(a)|b)+", "", "ab"],
  ["(a?)+?b", "", "ab"],
  ["(?:a*)*b", "", "aaab"],
  ["(?:a*?)*?b", "", "aab"],
  ["(a*)+", "", "b"],
  ["(a|)+", "", "aa"],
  ["^(?:(\\d)|x)*$", "", "1x2x"],
  ["(?=(\\w+))\\1:", "", "abc:"],
  ["(?!(a))\\1b", "", "b"],
  ["[\\d-z]+", "", "1-z"],
  ["[\\w-\\d]+", "", "a-1"],
  ["[a-\\d]", "", "-"],
  ["\\c", "", "\\c"],
  ["[\\c]", "", "c"],
  ["[\\c_]", "", "\x1f"],
  ["\\0", "", "\0"],
  ["\\07", "", "\x07"],
  ["\\377", "", "\xff"],
  ["\\400", "", "\x200"],
  ["a{,2}", "", "a{,2}"],
  ["\\x4", "", "x4"],
  ["\\u12", "", "u12"],
  ["(?<a>.)(?<b>.)\\k<b>\\k<a>", "", "abba"],
  ["\\k<a>", "", "k<a>"],
  ["\\p{L}", "", "p{L}"],
  ["ß", "iu", "ẞ"],
  ["ß", "i", "ẞ"],
  ["[^ß]", "iu", "ẞ"],
  ["\\u0130", "i", "i"],
  ["\\u0131", "i", "I"],
  ["\\u0130", "iu", "i"],
  ["[\\u0390]", "iu", "\u1fd3"],
  ["\\u03a3", "iu", "\u03c2"],
  ["Ǆ", "i", "ǅ"],
  ["ǆ", "iu", "ǅ"],
  ["\\w", "iv", "\u212a"],
  ["\\W", "iu", "\u017f"],
  ["\\W", "iv", "\u017f"],
  ["[^\\W]", "iu", "\u212a"],
  ["\\b", "iu", "\u017f"],
  ["\\P{Lu}", "iu", "A"],
  ["\\P{Lu}", "iv", "A"],
  ["[^\\P{Lu}]", "iv", "a"],
  ["\\p{Lu}", "iv", "a"],
  ["\\p{gc=Lu}", "iv", "a"],
  ["[\\p{Lu}--\\p{Ll}]", "iv", "a"],
  ["[\\q{AB}&&\\q{ab}]", "iv", "ab"],
  ["[[a-z]--\\q{a}]", "v", "a"],
  ["[\\q{}]", "v", "x"],
  ["[\\q{abc|ab}]", "v", "abc"],
  ["^.$", "u", "\ud800"],
  ["^.$", "u", "\udc00\ud800"],
  ["\\udc00", "u", "\ud800\udc00"],
  ["[\\ud800-\\udbff]", "u", "\ud800\udc00"],
  ["[\\ud800-\\udbff]", "", "\ud800\udc00"],
  ["(?<=\\ud800)\\udc00", "", "\ud800\udc00"],
  ["(?<=\\ud800)\\udc00", "u", "\ud800\udc00"],
  ["\\u{10000}", "u", "\ud800\udc00"],
  ["[\\u{10000}-\\u{10001}]", "u", "\ud800\udc01"],
  ["\\S", "u", "\ud83d\ude00"],
  ["a(?=b)", "y", "ab"],
  ["$", "m", "a\u2028b"],
  ["^", "gm", "a\nb\rc\u2029d"],
  ["\\B", "g", "ab cd"],
  ["(?i:[a-z])", "", "Q"],
  ["(?i:\\w)", "u", "\u017f"],
  ["(?m:^b)", "", "a\nb"],
  ["(?s:.)", "", "\n"],
  ["(?-s:.)", "s", "\n"],
  ["(?i:a(?-i:b))", "", "Ab AB"],
  ["x*y+$", "", "xxyy"],
  ["(x+x+)+y", "", "xxxxxxxxxxy"],
  ["a{2}{0}", "", "aa"],
  ["(?:)", "g", "ab"],
  ["\\d{3}|[a-z]{4}", "g", "2a fooba 123"],
  ["(\\d+)(?=(\\d{3})+(?!\\d))", "g", "1234567"],
  ["(?<!\\d)(?=(?:\\d{3})+$)", "g", "1234567"],
];
for (const [p, f, s] of cases) {
  let out: string;
  try {
    const re = new RegExp(p, f);
    const m = re.exec(s);
    out =
      m === null
        ? "null"
        : JSON.stringify([...m]) +
          "@" +
          m.index +
          (m.groups ? JSON.stringify({ ...m.groups }) : "");
    if (f.includes("g")) out += " all=" + JSON.stringify(s.match(re));
  } catch (e) {
    out = (e as Error).name;
  }
  console.log(JSON.stringify(p), f, out);
}
console.log(JSON.stringify("a1b2c3".split(/(\d)/, 3)), JSON.stringify("test".split(/(?:)/u, 2)));
console.log(
  JSON.stringify("\ud83d\ude00\ud83d\ude00".split(/(?:)/u)),
  JSON.stringify("aXbXc".split(/x/i)),
);
console.log(
  "aaa".replace(/a/gy, "b"),
  "baaa".replace(/a/gy, "b"),
  "x".replace(/x/, "$`$'$&$$$0$1"),
);
console.log("abc".replace(/(?<n>b)?c/, "[$<n>][$<m>][$<n]"), "abc".replace(/b/, "$<n>"));
const r = /a/g;
r.lastIndex = 5;
console.log(r.test("aaa"), r.lastIndex, "aaa".replace(r, "b"), r.lastIndex);
const y = /a/y;
y.lastIndex = 1;
console.log("aaa".replace(y, "b"), y.lastIndex, "bab".search(y), y.lastIndex);
console.log(
  JSON.stringify([..."a1b2".matchAll(/\d/g)].map((m) => m.index)),
  JSON.stringify("xyz".match(/(?<l>y)/)?.groups),
);
