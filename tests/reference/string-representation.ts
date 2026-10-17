// The representation of strings: UTF-16 code units, with Latin-1 text one byte per unit
// and other text two. Length and indexes count code units, a surrogate pair is two, a lone
// surrogate is a value of its own, and the two forms compare and join as one kind.

const latin = "café";
const wide = "naïve €uro";
const emoji = "a😀b";
console.log(latin.length, wide.length, emoji.length, emoji.codePointAt(1), emoji.charCodeAt(1));
console.log(emoji[1] === "\uD83D", emoji.slice(1, 3) === "😀", [...emoji].length, [...emoji][1]);
console.log(latin.toUpperCase(), wide.toUpperCase(), "ÉCOLE".toLowerCase(), "€".charCodeAt(0));

const lone = String.fromCharCode(0xd800);
console.log(lone.length, lone === "\uD800", lone + "\uDE00" === "𐈀");
console.log(JSON.stringify(lone), JSON.stringify("\uDE00x"), JSON.stringify("é€😀"));
console.log(JSON.parse('"\\u00e9\\u20ac"') === "é€", JSON.parse('{"k€y": "v"}')["k€y"]);

const joined = latin + wide;
console.log(
  joined,
  joined.length,
  joined.indexOf("€"),
  joined.lastIndexOf("é"),
  joined.slice(0, 4),
);
console.log(wide.slice(0, 5) === "naïve", wide.split(" "), wide.replace("€", "E"), wide.at(-1));
console.log(
  wide.includes("€u"),
  wide.startsWith("naï"),
  wide.endsWith("ro"),
  wide.padStart(12, "€"),
);

console.log("é" < "€", "€" < "😀", "Z" < "a", "a" < "é", "￿" > "😀", ["€", "é", "e"].sort());
console.log(String.fromCharCode(233, 8364, 0x1f600 & 0xffff), String.fromCodePoint(0x1f600).length);

const counts: Record<string, number> = {};
for (const ch of "aé€a") {
  counts[ch] = (counts[ch] ?? 0) + 1;
}
console.log(Object.keys(counts), counts["€"], "€" in counts);

const map = new Map<string, number>([["€", 1]]);
console.log(map.get("€"), map.get("€"), map.has("e"), `${latin}${wide}`.length);
console.log([wide, latin], { [wide]: latin });
