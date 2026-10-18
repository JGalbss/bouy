function main(): void {
  const s = "Hello, World";
  console.log(s.length, s.toUpperCase(), s.toLowerCase());
  console.log(s.slice(0, 5), s.slice(-5), s.substring(7));
  console.log(s.indexOf("o"), s.lastIndexOf("o"), s.indexOf("z"));
  console.log(s.includes("World"), s.startsWith("Hell"), s.endsWith("!"));
  console.log(s.split(", ").join(" | "));
  console.log("  padded  ".trim() + "|", "ab".repeat(3));
  console.log("5".padStart(3, "0"), "x".padEnd(4, "-") + "|");
  console.log(s.charAt(4), s[7], s.at(-1));
  console.log(s.replace("World", "Buoy"), "a-b-c".replaceAll("-", "+"));
  console.log("comma,separated,values".split(","));
  console.log(s.charCodeAt(0), String.fromCharCode(72, 105));
  const parts: string[] = [];
  for (const ch of "abc") {
    parts.push(ch.toUpperCase());
  }
  console.log(parts.join(""));
  console.log("b" > "a", "apple" < "banana", "Zebra" < "apple");
}

main();
