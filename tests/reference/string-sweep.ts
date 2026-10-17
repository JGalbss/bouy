// A deterministic sweep of String.prototype over generated strings of
// code units that include surrogates, combining marks, and special casings.
let seed = 4242;
function rand(): number {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
}
const pool = [
  "a",
  "B",
  "z",
  " ",
  "\t",
  "é",
  "ß",
  "Σ",
  "ς",
  "İ",
  "ı",
  "ﬁ",
  "😀",
  "\ud800",
  "\udc00",
  "́",
  "0",
  "-",
  " ",
  " ",
  "ǅ",
  "Ω",
  "ŉ",
];
const out: string[] = [];
for (let i = 0; i < 2000; i++) {
  let s = "";
  const n = Math.floor(rand() * 8);
  for (let j = 0; j < n; j++) s += pool[Math.floor(rand() * pool.length)];
  const a = Math.floor(rand() * 10) - 3,
    b = Math.floor(rand() * 10) - 3;
  const t = pool[Math.floor(rand() * pool.length)];
  out.push(
    JSON.stringify([
      s.length,
      s.slice(a, b),
      s.substring(a, b),
      s.substr(a, b),
      s.at(a),
      s.charCodeAt(a),
      s.codePointAt(a),
      s.indexOf(t, a),
      s.lastIndexOf(t, b),
      s.includes(t),
      s.startsWith(t, a),
      s.endsWith(t, b),
      s.padStart(b + 5, t),
      s.padEnd(a + 5, "xy"),
      s.trim(),
      s.trimStart(),
      s.toUpperCase(),
      s.toLowerCase(),
      s.normalize("NFD"),
      s.normalize("NFKC"),
      s.isWellFormed(),
      s.toWellFormed(),
      [...s].length,
      s.split(t).length,
      s.repeat(2).length,
      s.concat(t, 1),
    ]),
  );
}
console.log(out.join("\n"));
