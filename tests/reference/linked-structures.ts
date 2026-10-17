// Cyclic references, parent pointers, and in-place graph updates.
interface Node {
  id: number;
  parent: Node | null;
  children: Node[];
}
function node(id: number, parent: Node | null): Node {
  const n: Node = { id, parent, children: [] };
  if (parent) parent.children.push(n);
  return n;
}
const root = node(1, null);
const a = node(2, root);
const b = node(3, root);
const c = node(4, a);
c.parent!.parent!.id = 100;
console.log(root.id, a.parent === root, c.parent!.parent === root, b.parent!.children.length);

function depth(n: Node): number {
  let d = 0;
  for (let p = n.parent; p !== null; p = p.parent) d++;
  return d;
}
console.log(depth(c), depth(root));

type ListNode = { value: number; next: ListNode | null };
let head: ListNode | null = null;
for (let i = 5; i > 0; i--) head = { value: i, next: head };
let reversed: ListNode | null = null;
while (head) {
  const next: ListNode | null = head.next;
  head.next = reversed;
  reversed = head;
  head = next;
}
const values: number[] = [];
for (let p = reversed; p; p = p.next) values.push(p.value);
console.log(values);

const ring: { name: string; next?: unknown } = { name: "ring" };
ring.next = ring;
console.log(ring.next === ring);
