function isPalindrome(text: string): boolean {
  const cleaned = text
    .toLowerCase()
    .split("")
    .filter((ch) => ch >= "a" && ch <= "z")
    .join("");
  return cleaned === cleaned.split("").reverse().join("");
}

function caesar(text: string, shift: number): string {
  let out = "";
  for (const ch of text) {
    const code = ch.charCodeAt(0);
    if (code >= 97 && code <= 122) {
      out += String.fromCharCode(((code - 97 + shift + 26) % 26) + 97);
    } else {
      out += ch;
    }
  }
  return out;
}

function reverseWords(sentence: string): string {
  return sentence.split(" ").reverse().join(" ");
}

function longestCommonPrefix(words: string[]): string {
  if (words.length === 0) return "";
  let prefix = words[0];
  for (const word of words.slice(1)) {
    while (!word.startsWith(prefix)) {
      prefix = prefix.slice(0, -1);
    }
  }
  return prefix;
}

function compress(text: string): string {
  let result = "";
  let i = 0;
  while (i < text.length) {
    let run = 1;
    while (i + run < text.length && text[i + run] === text[i]) run++;
    result += run > 1 ? `${text[i]}${run}` : text[i];
    i += run;
  }
  return result;
}

function main(): void {
  console.log(isPalindrome("A man, a plan, a canal: Panama"), isPalindrome("buoy"));
  console.log(caesar("hello, world", 3), caesar(caesar("abc xyz", 5), -5));
  console.log(reverseWords("actors run on the beam"));
  console.log(
    longestCommonPrefix(["interstellar", "internet", "interval"]),
    longestCommonPrefix(["a", "b"]),
  );
  console.log(compress("aaabccddddde"), compress(""), compress("abc"));
}

main();
