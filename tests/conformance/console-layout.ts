// console.log lays out text as Node does: line breaks count UTF-16 code
// units, array columns count terminal columns, %o shows hidden properties,
// and long nested strings are cut.

function main(): void {
  console.log({ a: "😀".repeat(20), b: "😀".repeat(19) });
  console.log({ a: "x".repeat(20), b: "y".repeat(19) });
  console.log(["東京", "大阪", "京都", "札幌", "福岡", "神戸", "横浜", "名古屋", "仙台", "広島"]);
  console.log(["ééé", "x", "y", "z", "w", "v", "u", "t"]);
  console.log(["é", "a", "b", "c", "d", "e", "f", "g", "h"]);
  console.log(["😀", "😀😀", "a", "b", "c", "d", "e", "f"]);
  console.log("%o", [1, 2]);
  console.log("%o", { list: [1, [2]] });
  console.log("%o", []);
  console.log(["x".repeat(10001)]);
  console.log({ text: "é".repeat(10002) }.text.length, [["y".repeat(10002)]].flat()[0].length);
  console.log([["z".repeat(10002)]]);
  console.log(JSON.parse('{"__proto__": 1}'));
}

main();
