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
