// String.prototype over UTF-16 code units: indexing, searching, padding,
// case mapping with special casing, normalization, and well-formedness.
const text = "Straße ΑΣ 😀 café";
console.log(text.length, text.at(-1), text.charCodeAt(11), text.codePointAt(10), [...text].length);
console.log(text.toUpperCase(), text.toLowerCase(), "ΣΑΣ".toLowerCase(), "İ".toLowerCase().length);
console.log(
  "abc".padStart(7, "12"),
  "abc".padEnd(5),
  "ab".repeat(3),
  "  x  ".trim() + "|",
  " y".trimStart(),
);
console.log(
  "abcabc".indexOf("c", 3),
  "abcabc".lastIndexOf("b"),
  "abc".includes("bc"),
  "abc".startsWith("b", 1),
  "abc".endsWith("b", 2),
);
console.log(
  "abcdef".slice(-3, -1),
  "abcdef".substring(4, 1),
  "abcdef".substr(-4, 2),
  "a-b-c".split("-", 2),
);
console.log(
  "é".normalize("NFC").length,
  "é".normalize("NFD").length,
  "a\uD800b".isWellFormed(),
  "a\uD800b".toWellFormed().charCodeAt(1),
);
console.log(
  "a".localeCompare("B"),
  "b".localeCompare("a"),
  "ö".localeCompare("ö"),
  String.fromCodePoint(0x1f600).length,
);
console.log(
  String.raw`a\n${1}b`,
  String.fromCharCode(65, 0x10041),
  "abc"[Symbol.iterator]().next().value,
);

// Case maps and replaceAll of strings longer than one native call: a sum of the code
// units at their positions stands for each result.
function digest(s: string): string {
  let sum = 0;
  for (let i = 0; i < s.length; i++) sum = (sum * 31 + s.charCodeAt(i) * (i + 1)) % 1000000007;
  return `${s.length}:${sum}`;
}
const latin = "Aß µ ÿz Ñ×Þ é! ".repeat(40000);
console.log(
  digest(latin.toUpperCase()),
  digest(latin.toLowerCase()),
  digest(latin.toUpperCase().toLowerCase()),
);
const greek = "ΟΔΟΣ ΑΣ. ΣΑ Σ ΑΣ' Σ😀 ".repeat(3000) + "ΑΣ";
console.log(
  digest(greek.toLowerCase()),
  digest(greek.toUpperCase()),
  greek.toLowerCase().slice(-6),
);
const lone = "a\uD800ΣB\uDC00".repeat(5000);
console.log(digest(lone.toLowerCase()), digest(lone.toUpperCase()));
const csv = "id,item-7,σ,x\n".repeat(30000);
console.log(
  digest(csv.replaceAll(",", ";")),
  digest(csv.replaceAll("item-", "")),
  digest(csv.replaceAll(",", "→")),
  digest(csv.replaceAll("σ", "s")),
  digest(csv.replaceAll("\n", "")),
  digest(latin.replaceAll("ß µ", "_")),
  digest(latin.replaceAll("none", "x")),
);
console.log(
  "䄀䈀".replaceAll("B", "x") === "䄀䈀",
  "aaaa".replaceAll("aa", "b"),
  "x$y".replaceAll("$", "$$"),
);
