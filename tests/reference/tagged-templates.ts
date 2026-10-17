// Tagged templates: the cooked and raw strings, the substitutions, a
// method as the tag, and one frozen template object per site.
function tag(strings: TemplateStringsArray, ...values: unknown[]): string {
  return strings.raw.join("|") + " / " + strings.join("|") + " / " + values.join(",");
}
console.log(tag`a${1}b\n${2 + 3}c`);
const objects: TemplateStringsArray[] = [];
for (let i = 0; i < 2; i++) {
  objects.push(((strings: TemplateStringsArray) => strings)`same site`);
}
console.log(
  objects[0] === objects[1],
  Object.isFrozen(objects[0]),
  Object.isFrozen(objects[0].raw),
);
const greeter = {
  prefix: "Hi",
  greet(strings: TemplateStringsArray, name: string): string {
    return this.prefix + strings[0] + name + strings[1];
  },
};
console.log(greeter.greet`, ${"Ada"}!`, String.raw`\u{61}${"b"}\t`);
