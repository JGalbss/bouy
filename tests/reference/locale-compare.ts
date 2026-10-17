// localeCompare against ICU's root collation: punctuation, digits, and
// letters in order, accents and case as later levels, and the letters
// that expand, such as ß; a fixed list and a generated sort.
const words = [
  "apple",
  "Apple",
  "APPLE",
  "äpple",
  "banana",
  "Banana",
  "zebra",
  "Zebra",
  "éclair",
  "eclair",
  "Eclair",
  "a",
  "A",
  "aa",
  "ab",
  "a b",
  "a-b",
  "a_b",
  "1",
  "10",
  "2",
  "_x",
  "-x",
  " x",
  "x",
  "ß",
  "ss",
  "SS",
  "straße",
  "strasse",
  "Ωmega",
  "omega",
  "naïve",
  "naive",
  "résumé",
  "resume",
  "Resume",
  "co-op",
  "coop",
  "co op",
  "@home",
  "#tag",
  "",
  "Ä",
  "ä",
  "à",
  "á",
];
console.log([...words].sort((a, b) => a.localeCompare(b)).join(","));
const pairs: string[] = [];
for (const a of words.slice(0, 20))
  for (const b of words.slice(20)) pairs.push(String(a.localeCompare(b)));
console.log(pairs.join(""));
let seed2 = 8;
function rand2(): number {
  seed2 = (seed2 * 1103515245 + 12345) % 2147483648;
  return seed2 / 2147483648;
}
const pool2 = [
  "a",
  "A",
  "b",
  "B",
  "e",
  "é",
  "è",
  "É",
  "ê",
  "o",
  "ö",
  "Ö",
  "ø",
  "s",
  "ß",
  "z",
  "Z",
  "1",
  "2",
  "0",
  " ",
  "-",
  "_",
  ".",
  "æ",
  "ç",
  "ñ",
  "Ω",
  "ω",
  "ж",
  "Ж",
  "あ",
  "中",
  "!",
];
const words2: string[] = [];
for (let i = 0; i < 400; i++) {
  let w = "";
  const n = 1 + Math.floor(rand2() * 5);
  for (let j = 0; j < n; j++) w += pool2[Math.floor(rand2() * pool2.length)];
  words2.push(w);
}
console.log(
  words2
    .slice()
    .sort((a, b) => a.localeCompare(b) || (a < b ? -1 : a > b ? 1 : 0))
    .join("|"),
);
