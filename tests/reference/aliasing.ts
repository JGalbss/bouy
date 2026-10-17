// Two names for one object see each other's writes.
const a = { x: 0, nested: { y: 1 } };
const b = a;
b.x = 1;
b.nested.y = 2;
console.log(a.x, a.nested.y, a === b);

const list: number[] = [];
const alias = list;
alias.push(1, 2);
list.push(3);
console.log(list, alias.length, list === alias);

function mutate(target: { count: number }): void {
  target.count += 10;
}
const box = { count: 1 };
mutate(box);
mutate(box);
console.log(box.count);

const copy = { ...a };
copy.x = 99;
console.log(a.x, copy.x, copy.nested === a.nested);
